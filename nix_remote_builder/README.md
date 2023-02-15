# Goal

This script is supposed to automatically configure [nix distributed builds](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html) through your machines to create a kind of nix cluster.
 

# Prerequisite :

- Nix is installed through nix-daemon
- Builder manage nix daemon through launchctl or systemctl
- SSH access through ssh key managed by ssh agent to be able to execute command
  onto servers (for each used user)
  - run `ssh-copy-id <USER>@<IP>`
- Root user of master server have to be able to login onto each builders
  - ensure root user got identity if no create it by running `sudo ssh-keygen`
  - run `sudo ssh-copy-id <USER>@<IP>` for each builders manually
- Runner user of master server have to be able to login onto each builders
  - ensure runner user got identity if no create it by running `sudo ssh-keygen`
  - run `sudo ssh-copy-id <USER>@<IP>` for each builders manually
- sudoers users have to be able to run `sudo` without password
- User used on master-SSH-URI have to be sudoers
- On each builders, nix have to be inside (version 2.12.0)
- bash 5.x

After run you can test than everything work by connect into master machine and
run `nix build   --option substitute false --impure   --expr '(with import <nixpkgs> { system = "${ARCH}"; }; runCommand "foo" {} "uname > $out")'`

# Run

Simply run `./main.sh` after ensure prerequisite are ok.
The script gonna use sudo on your machines, please check it before run it blindly 
