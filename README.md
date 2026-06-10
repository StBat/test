# test

### Setup

Log in to the server via SSH and run the following commands
(step-by-step explanation in next section)

```sh
sudo su -
dnf update -y
dnf install -y git python3
cd /apps
git clone https://github.com/nanome-ai/nanome-ai-deployer
-- git clone https://github.com/StBat/test
-- cp /apps/test/playbooks/aws_configure.yaml /apps/nanome-ai-deployer/cli/playbooks/aws_configure.yaml
-- cp /apps/test/playbooks/install_docker.yaml /apps/nanome-ai-deployer/cli/playbooks/install_docker.yaml
-- cp /apps/test/playbooks/install_awscli.yaml /apps/nanome-ai-deployer/cli/playbooks/install_awscli.yaml
cd nanome-ai-deployer
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python install_prereqs.py
reboot now
```

After reboot
```sh
sudo su -
cd /apps/nanome-ai-deployer
source venv/bin/activate
python setup_nanome.py
docker compose up -d
```
