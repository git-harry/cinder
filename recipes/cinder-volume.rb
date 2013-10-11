#
# Cookbook Name:: cinder
# Recipe:: cinder-volume
#
# Copyright 2012, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/shell_out'

platform_options = node["cinder"]["platform"]

pkgs = platform_options["cinder_volume_packages"] + platform_options["cinder_iscsitarget_packages"]

pkgs.each do |pkg|
  package pkg do
    action node["osops"]["do_package_upgrades"] == true ? :upgrade : :install
    options platform_options["package_overrides"]
  end
end

include_recipe "cinder::cinder-common"

# set to enabled right now but can be toggled
service "cinder-volume" do
  service_name platform_options["cinder_volume_service"]
  supports :status => true, :restart => true
  action [ :enable ]
  subscribes :restart, "cinder_conf[/etc/cinder/cinder.conf]", :delayed
end

service "iscsitarget" do
  service_name platform_options["cinder_iscsitarget_service"]
  supports :status => true, :restart => true
  action :enable
end

template "/etc/tgt/targets.conf" do
  source "targets.conf.erb"
  mode "600"
  notifies :restart, "service[iscsitarget]", :immediately
end

case node["cinder"]["storage"]["provider"]
  when "emc"
    d = node["cinder"]["storage"]["emc"]
    keys = %w[StorageType EcomServerIP EcomServerPort EcomUserName EcomPassword]
    for word in keys
      if not d.key? word
        msg = "Cinder's emc volume provider was selected, but #{word} was not set.'"
        Chef::Application.fatal! msg
      end
    end
    node["cinder"]["storage"]["emc"]["packages"].each do |pkg|
      package pkg do
        action node["osops"]["do_package_upgrades"] == true ? :upgrade : :install
      end
    end

    template node["cinder"]["storage"]["emc"]["config"] do
      source "cinder_emc_config.xml.erb"
      variables d
      mode "644"
      notifies :restart, "service[iscsitarget]", :immediately
    end
  when "netappnfsdirect"
    node["cinder"]["storage"]["netapp"]["nfsdirect"]["packages"].each do |pkg|
      package pkg do
        action node["osops"]["do_package_upgrades"] == true ? :upgrade : :install
      end
    end

    template node["cinder"]["storage"]["netapp"]["nfsdirect"]["nfs_shares_config"] do
      source "cinder_netapp_nfs_shares.txt.erb"
      mode "0600"
      owner "cinder"
      group "cinder"
      variables(
       "host" => node["cinder"]["storage"]["netapp"]["nfsdirect"]["server_hostname"],
       "nfs_export" => node["cinder"]["storage"]["netapp"]["nfsdirect"]["export"]
      )
      notifies :restart, "service[cinder-volume]", :delayed
    end
  when "lvm"
    template node["cinder"]["storage"]["lvm"]["config"] do
      source "lvm.conf.erb"
      mode 0644
      variables(
        "volume_group" => node["cinder"]["storage"]["lvm"]["volume_group"]
      )
    end

  when "rbd"

    # Ensure the rbd user exists and has appropriate pool permissions).
    # Also grab user key and set it to the node object so it's searchable
    # as nova::libvirt needs it

    rbd_user = node['cinder']['storage']['rbd']['rbd_user']
    rbd_pool = node['cinder']['storage']['rbd']['rbd_pool']
    rbd_secret_uuid = node['cinder']['storage']['rbd']['rbd_secret_uuid']

    # get (or create) the cinder rbd user in cephx
    # TODO(mancdaz): get glance pool name by search, and only grant access if glance is using rbd
    Mixlib::ShellOut.new("ceph auth get-or-create client.#{rbd_user}").run_command
    Mixlib::ShellOut.new("ceph auth caps client.#{rbd_user} mon 'allow r' osd 'allow class-read object_prefix rbd_children, allow rwx pool=#{rbd_pool}, allow rx pool=images'").run_command

    # get the key for this user and set it to the node hash
    rbd_user_key = Mixlib::ShellOut.new("ceph auth get-key client.#{rbd_user} ").run_command.stdout
    Chef::Log.info("rbd_user_key is: #{rbd_user_key}")
    node.set['cinder']['storage']['rbd']['rbd_user_key'] = rbd_user_key

    # get the full client, with caps, and write it out to file
    # TODO(mancdaz): discover ceph config dir rather than hardcode
    rbd_user_keyring = Mixlib::ShellOut.new("ceph auth get client.#{rbd_user}").run_command.stdout
    file "/etc/ceph/ceph.client.#{rbd_user}.keyring" do
      content rbd_user_keyring
      mode "0644"
    end

end
