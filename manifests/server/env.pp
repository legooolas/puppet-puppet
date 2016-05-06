# Set up a puppet environment
define puppet::server::env (
  $basedir                = $::puppet::server::envs_dir,
  $config_version         = $::puppet::server::config_version_cmd,
  $manifest               = undef,
  $manifestdir            = undef,
  $modulepath             = ["${::puppet::server::envs_dir}/${name}/modules", $::puppet::server::common_modules_path],
  $templatedir            = undef,
  $environment_timeout    = $::puppet::server::environment_timeout,
  $directory_environments = $::puppet::server::directory_environments,
  $owner                  = $::puppet::server::environments_owner,
  $group                  = $::puppet::server::environments_group,
  $mode                   = $::puppet::server::environments_mode,
) {
  file { "${basedir}/${name}":
    ensure => directory,
    owner  => $owner,
    group  => $group,
    mode   => $mode,
  }

  file { "${basedir}/${name}/modules":
    ensure => directory,
    owner  => $owner,
    group  => $group,
    mode   => $mode,
  }

  if $directory_environments {
    file { "${basedir}/${name}/manifests":
      ensure => directory,
      owner  => $owner,
      group  => $group,
      mode   => $mode,
    }

    $custom_modulepath = $modulepath and ($modulepath != ["${basedir}/${name}/modules", $::puppet::server::common_modules_path])
    if $manifest or $config_version or $custom_modulepath or $environment_timeout {
      file { "${basedir}/${name}/environment.conf":
        ensure  => file,
        owner   => $owner,
        group   => $group,
        mode    => '0644',
        content => template('puppet/server/environment.conf.erb'),
      }
    }
  } else {
    concat::fragment { "puppet.conf+40-${name}":
      target  => "${::puppet::dir}/puppet.conf",
      content => template('puppet/server/puppet.conf.env.erb'),
      order   => '40',
    }
  }
}
