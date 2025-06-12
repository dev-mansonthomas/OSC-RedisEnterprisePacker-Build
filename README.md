# Redis Enterprise Packer Images on AWS

This project builds AWS AMIs for Redis Enterprise using [Packer](https://www.packer.io/) and automates the setup and teardown of the required AWS infrastructure.

## Requirements

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured and authenticated)
- [Packer](https://www.packer.io/downloads)
- [jq](https://stedolan.github.io/jq/) (for parsing JSON in shell scripts)
- Bash shell (tested on Linux/macOS)
- Registered AWS key pair (for SSH access)
- Sufficient AWS permissions to create/delete VPCs, subnets, route tables, security groups, EC2 instances, and AMIs

### Install Packer

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/packer
```

### AWS Credentials Setup

1. **Create a Service Account (IAM User) in AWS Console:**
   - Go to IAM > Users > Add user
   - Assign programmatic access
   - Attach policies: `AmazonEC2FullAccess`, `AmazonVPCFullAccess`, `IAMReadOnlyAccess` (minimum required)
   - Download the Access Key ID and Secret Access Key

2. **Configure AWS CLI:**

```sh
aws configure
```

Example prompts:

```
AWS Access Key ID [None]: XXX
AWS Secret Access Key [None]: YYYY
Default region name [None]: eu-west-3
Default output format [None]: json
```

## Usage

Run the following scripts in order from the project root:

1. **Provision AWS Infrastructure:**

   ```sh
   cd aws/
   aws-setup.sh
   ```

2. **Build and Deploy the Packer Image:**

   ```sh
   cd build_scripts/
   build_and_deploy_image_with_packer.sh
   ```

3. **Instantiate an EC2 Instance from the Built Image:**

   ```sh
   cd aws/
   my_instanciate.sh
   ```

4. **Connect to Your Instance:**

   ```sh
   cd aws/
   connect_to_my_instance.sh 1
   ```

   (Replace `1` with the subnet index if needed.)

## Teardown

When finished, destroy all created AWS resources:

```sh
cd aws/
teardown-aws-vpc.sh
```

---

## Notes

- The project uses [`packer/ubuntu_ufw_aws_image.pkr.hcl`](packer/ubuntu_ufw_aws_image.pkr.hcl ) as the Packer template.
- Redis Enterprise tarball must be present in [`redis-software`](redis-software ).
- Environment variables for resource IDs are stored in `_my_env.sh` (auto-generated).
- All scripts assume the default AWS region is `eu-west-3`.

---

TODO : 
* gestion des mounts points
* installation scriptée
* Ajout de la license
