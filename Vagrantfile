Vagrant.configure("2") do |config|
  # VM 1 : VPN Bastion
  config.vm.define "guaccetwireguard" do |vpn|
    vpn.vm.box = "debian/bookworm64"
    vpn.vm.hostname = "BastionGuaccamoleWireguard"
    vpn.vm.network "private_network", ip: "192.168.56.10"
    vpn.vm.network "forwarded_port", guest: 22, host: 2223, id: "ssh"
    vpn.ssh.guest_port = 2223
    vpn.vm.synced_folder ".", "/vagrant1"
    
    vpn.vm.provider "virtualbox" do |vb|
      vb.name = "vpn"
      vb.memory = 2048
      vb.cpus = 1
    end
  end
  
  # VM 2 : Serveur known-hosts
  config.vm.define "knowcked" do |knowcked|
    knowcked.vm.box = "debian/bookworm64"
    knowcked.vm.hostname = "server"
    knowcked.vm.network "private_network", ip: "192.168.56.11"
    knowcked.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh"
    knowcked.ssh.guest_port = 2222
    knowcked.vm.synced_folder ".", "/vagrant2"
    
    knowcked.vm.provider "virtualbox" do |vb|
      vb.name = "srvknowcked"
      vb.memory = 2048
      vb.cpus = 1
    end
  end
  
  # VM 3 : Serveur de Test Ansible
  config.vm.define "SrvAnsible" do |ansible|
    ansible.vm.box = "debian/bookworm64"
    ansible.vm.hostname = "SrvAnsible"
    ansible.vm.network "private_network", ip: "192.168.56.12"
    ansible.vm.network "forwarded_port", guest: 22, host: 2224, id: "ssh"
    ansible.ssh.guest_port = 2224
    ansible.vm.synced_folder ".", "/vagrant3"
    
    ansible.vm.provider "virtualbox" do |vb|
      vb.name = "SrvAnsible"
      vb.memory = 2048
      vb.cpus = 1
    end
  end
end
