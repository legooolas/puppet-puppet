# Set up the puppet server config
class puppet::server::config inherits puppet::config {
  if $::puppet::server::passenger and $::puppet::server::implementation == 'master' {
    # Anchor the passenger config inside this
    class { '::puppet::server::passenger': } -> Class['puppet::server::config']
  }

  if $::puppet::server::implementation == 'puppetserver' {
    include ::puppet::server::puppetserver
    anchor {'::puppet::server::puppetserver_start': } ->
    Class['::puppet::server::puppetserver'] ~>
    anchor {'::puppet::server::puppetserver_end': }
  }

  # Mirror the relationship, as defined() is parse-order dependent
  # Ensures puppetmasters certs are generated before the proxy is needed
  if defined(Class['foreman_proxy::config']) and $foreman_proxy::ssl {
    Class['puppet::server::config'] ~> Class['foreman_proxy::config']
    Class['puppet::server::config'] ~> Class['foreman_proxy::service']
  }

  ## General configuration
  $ca_server                   = $::puppet::ca_server
  $ca_port                     = $::puppet::ca_port
  $server_storeconfigs_backend = $::puppet::server::storeconfigs_backend
  $server_external_nodes       = $::puppet::server::external_nodes
  $server_environment_timeout  = $::puppet::server::environment_timeout

  if $server_external_nodes and $server_external_nodes != '' {
    $server_node_terminus = 'exec'
  } else {
    $server_node_terminus = 'plain'
  }

  concat::fragment { 'puppet.conf+30-master':
    target  => "${::puppet::dir}/puppet.conf",
    content => template($::puppet::server::template),
    order   => '30',
  }
  concat::fragment { 'puppet.conf+15-main-master':
    target  => "${::puppet::dir}/puppet.conf",
    content => template($::puppet::server::main_template),
    order   => '15',
  }


  file { "${puppet::vardir}/reports":
    ensure => directory,
    owner  => $::puppet::server::user,
    group  => $::puppet::server::group,
    mode   => '0750',
  }

  ## SSL and CA configuration
  # Open read permissions to private keys to puppet group for foreman, proxy etc.
  file { "${::puppet::server::ssl_dir}/private_keys":
    ensure  => directory,
    owner   => $::puppet::server::user,
    group   => $::puppet::server::group,
    mode    => '0750',
    require => Exec['puppet_server_config-create_ssl_dir'],
  }

  file { "${::puppet::server::ssl_dir}/private_keys/${::puppet::server::certname}.pem":
    owner => $::puppet::server::user,
    group => $::puppet::server::group,
    mode  => '0640',
  }

  # 3.4.0+ supports umask
  if versioncmp($::puppetversion, '3.4.0') >= 0 {
    # If the ssl dir is not the default dir, it needs to be created before running
    # the generate ca cert or it will fail.
    exec {'puppet_server_config-create_ssl_dir':
      creates => $::puppet::server::ssl_dir,
      command => "/bin/mkdir -p ${::puppet::server::ssl_dir}",
      umask   => '0022',
    }

    # Generate a new CA and host cert if our host cert doesn't exist
    if $::puppet::server::ca {
      exec {'puppet_server_config-generate_ca_cert':
        creates => $::puppet::server::ssl_cert,
        command => "${::puppet::puppetca_cmd} --generate ${::puppet::server::certname}",
        umask   => '0022',
        require => [Concat["${::puppet::server::dir}/puppet.conf"],
                    Exec['puppet_server_config-create_ssl_dir'],
                    ],
      }
    }
  } else {
    # Copy of above without umask for pre-3.4
    exec {'puppet_server_config-create_ssl_dir':
      creates => $::puppet::server::ssl_dir,
      command => "/bin/mkdir -p ${::puppet::server::ssl_dir}",
    }

    if $::puppet::server::ca {
      exec {'puppet_server_config-generate_ca_cert':
        creates => $::puppet::server::ssl_cert,
        command => "${::puppet::puppetca_cmd} --generate ${::puppet::server::certname}",
        require => [Concat["${::puppet::server::dir}/puppet.conf"],
                    Exec['puppet_server_config-create_ssl_dir'],
                    ],
      }
    }
  }

  if $::puppet::server::passenger and $::puppet::server::implementation == 'master' and $::puppet::server::ca {
    Exec['puppet_server_config-generate_ca_cert'] ~> Service[$::puppet::server::httpd_service]
  }

  # autosign file
  if $::puppet::server_ca and ! is_bool($puppet::autosign) {
    file { $puppet::autosign:
      ensure => file,
      owner  => $puppet::user,
      group  => $puppet::group,
      mode   => $puppet::autosign_mode,
    }
  }

  # only manage this file if we provide content
  if $::puppet::server::default_manifest and $::puppet::server::default_manifest_content != '' {
    file { $::puppet::server::default_manifest_path:
      ensure  => file,
      owner   => $puppet::user,
      group   => $puppet::group,
      mode    => '0644',
      content => $::puppet::server::default_manifest_content,
    }
  }

  ## Environments
  # location where our puppet environments are located
  file { $::puppet::server::envs_dir:
    ensure => directory,
    owner  => $::puppet::server::environments_owner,
    group  => $::puppet::server::environments_group,
    mode   => $::puppet::server::environments_mode,
  }

  if $::puppet::server::git_repo {
    # need to chown the $vardir before puppet does it, or else
    # we can't write puppet.git/ on the first run

    include ::git

    git::repo { 'puppet_repo':
      bare    => true,
      target  => $::puppet::server::git_repo_path,
      mode    => $::puppet::server::git_repo_mode,
      user    => $::puppet::server::git_repo_user,
      group   => $::puppet::server::git_repo_group,
      require => File[$::puppet::server::envs_dir],
    }

    $git_branch_map = $::puppet::server::git_branch_map
    # git post hook to auto generate an environment per branch
    file { "${::puppet::server::git_repo_path}/hooks/${::puppet::server::post_hook_name}":
      content => template($::puppet::server::post_hook_content),
      owner   => $::puppet::server::git_repo_user,
      group   => $::puppet::server::git_repo_group,
      mode    => $::puppet::server::git_repo_mode,
      require => Git::Repo['puppet_repo'],
    }

  }
  elsif ! $::puppet::server::dynamic_environments {
    file { $puppet::sharedir:
      ensure => directory,
    }

    file { $::puppet::server::common_modules_path:
      ensure => directory,
      owner  => $::puppet::server::environments_owner,
      group  => $::puppet::server::environments_group,
      mode   => $::puppet::server::environments_mode,
    }

    # make sure your site.pp exists (puppet #15106, foreman #1708) and server_manifest_path too
    file { $::puppet::server::manifest_path:
      ensure => directory,
      owner  => $::puppet::server::user,
      group  => $::puppet::server::group,
      mode   => '0755',
    }
    file { "${::puppet::server::manifest_path}/site.pp":
      ensure  => file,
      replace => false,
      content => "# site.pp must exist (puppet #15106, foreman #1708)\n",
      mode    => '0644',
    }

    # setup empty directories for our environments
    puppet::server::env {$::puppet::server::environments: }
  }

  ## Foreman
  if $::puppet::server::foreman {
    # Include foreman components for the puppetmaster
    # ENC script, reporting script etc.
    anchor { 'puppet::server::config_start': } ->
    class {'::foreman::puppetmaster':
      foreman_url    => $::puppet::server::foreman_url,
      receive_facts  => $::puppet::server::server_facts,
      puppet_home    => $puppet::vardir,
      puppet_basedir => $::puppet::server::puppet_basedir,
      puppet_etcdir  => $puppet::dir,
      enc_api        => $::puppet::server::enc_api,
      report_api     => $::puppet::server::report_api,
      timeout        => $::puppet::server::request_timeout,
      ssl_ca         => pick($::puppet::server::foreman_ssl_ca, $::puppet::server::ssl_ca_cert),
      ssl_cert       => pick($::puppet::server::foreman_ssl_cert, $::puppet::server::ssl_cert),
      ssl_key        => pick($::puppet::server::foreman_ssl_key, $::puppet::server::ssl_cert_key),
    } ~> anchor { 'puppet::server::config_end': }
  }

  ## PuppetDB
  if $::puppet::server::puppetdb_host {
    class { '::puppetdb::master::config':
      puppetdb_server             => $::puppet::server::puppetdb_host,
      puppetdb_port               => $::puppet::server::puppetdb_port,
      puppetdb_soft_write_failure => $::puppet::server::puppetdb_swf,
      manage_storeconfigs         => false,
      restart_puppet              => false,
    }
    Class['puppetdb::master::puppetdb_conf'] ~> Class['puppet::server::service']
  }
}
