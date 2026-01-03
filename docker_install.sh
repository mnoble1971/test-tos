dnf install -y dnf-plugins-core ca-certificates curl gnupg lvm2
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
# test with docker run hello-world