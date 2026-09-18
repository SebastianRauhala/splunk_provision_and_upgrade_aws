#!/bin/bash
#
# Splunk Provisioning Script for AWS EC2
# Author: Sebastian Rauhala
#

# --- Configuration ---
USER="ec2-user"
DEF_KEY="$HOME/.ssh/lab_key.pem" # Path to your private SSH key, download yours from AWS console. 
SPLUNK_DOWNLOADS_PATH="$HOME/Downloads/"

# --- Remote Commands ---
SUDO_DNF_UPDATE="sudo dnf update -y"
JAVA_PACKAGE="java-11-amazon-corretto-devel"
SUDO_INSTALL_JAVA="sudo dnf install $JAVA_PACKAGE -y"
CHOWN_SPLUNK_APPS="sudo chown -R splunk:splunk /opt/splunk/etc/apps/"
CHOWN_SPLUNK_FULL="sudo chown -R splunk:splunk /opt/splunk"
RESTART_SPLUNK="sudo systemctl restart Splunkd.service"
SPLUNKD_STATUS="systemctl --no-pager status Splunkd.service"

# --- Splunk Enterprise Installation Data ---
SPLUNK_VERSIONS=( "Splunk Enterprise 10.2.0" "Splunk Enterprise 10.0.2" "Splunk Enterprise 10.0.1" "Splunk Enterprise 10.0.0" "Splunk Enterprise 9.4.3" "Splunk Enterprise 9.4.2" "Splunk Enterprise 9.4.1" "Splunk Enterprise 9.3.6" "Splunk Enterprise 9.2.8" "Splunk Enterprise 9.1.10" )
SPLUNK_FILENAMES=( "splunk-10.2.0-d749cb17ea65.x86_64.rpm" "splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "splunk-10.0.1-c486717c322b.x86_64.rpm" "splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "splunk-9.4.3-237ebbd22314.x86_64.rpm" "splunk-9.4.2-e9664af3d956.x86_64.rpm" "splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "splunk-9.2.8-811db24f0af2.x86_64.rpm" "splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )
SPLUNK_URLS=( "https://download.splunk.com/products/splunk/releases/10.2.0/linux/splunk-10.2.0-d749cb17ea65.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.2/linux/splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.1/linux/splunk-10.0.1-c486717c322b.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.0/linux/splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.3/linux/splunk-9.4.3-237ebbd22314.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.2/linux/splunk-9.4.2-e9664af3d956.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.1/linux/splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.3.6/linux/splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.2.8/linux/splunk-9.2.8-811db24f0af2.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.1.10/linux/splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )


# --- Function Definitions ---

print_header() {
    cat << "EOF"
                                                                    
  _________      .__                __     .___                 __         .__  .__   
 /   _____/_____ |  |  __ __  ____ |  | __ |   | ____   _______/  |______  |  | |  |  
 \_____  \\____ \|  | |  |  \/    \|  |/ / |   |/    \ /  ___/\   __\__  \ |  | |  |  
 /        \  |_> >  |_|  |  /   |  \    <  |   |   |  \\___ \  |  |  / __ \|  |_|  |__
/_______  /   __/|____/____/|___|  /__|_ \ |___|___|  /____  > |__| (____  /____/____/
        \/|__|                   \/     \/          \/     \/            \/           
                        on AWS                                      

EOF
    echo "======================================================================="
    echo "                 Author: Sebastian Rauhala"
    echo "======================================================================="
    echo ""
    echo "This script automates the provisioning of a Splunk instance on an"
    echo "Amazon Linux 2023 EC2 instance."
    echo "Built with Circuit"
    echo "------------------------- User Pre-requisites -------------------------"
    echo "1. A running Amazon Linux 2023 EC2 instance."
    echo "2. The public IP address of the instance."
    echo "3. Splunk Admin credentials (username/password). For a fresh install,"
    echo "   you will set this password on first start via the script."
    echo "4. Any Splunk Apps (*.spl) or Licenses (*.lic) placed in your"
    echo "   local '~/Downloads' directory."
    echo ""
    echo "--------------------------- Script Actions ----------------------------"
    echo "The script will guide you through the following steps:"
    echo "1. Check for a local SSH key and help you create one if it's missing."
    echo "2. Prompt for the EC2 instance's IP and a new Splunk Admin password."
    echo "3. Offer to install a selected version of Splunk Enterprise."
    echo "4. Offer to install and activate any available license files."
    echo "5. Offer to install Java (Amazon Corretto)."
    echo "6. Allow you to install Splunk Apps and restart the Splunk service."
    echo ""
    echo "======================================================================="
    read -p "Press [Enter] to begin..."
    echo ""
}

check_and_setup_ssh_key() {
    local key_path="$DEF_KEY"
    local pub_key_path="${key_path}.pub"
    if [ -f "$key_path" ]; then
        echo "✅ SSH key found at $key_path."
        return 0
    fi
    echo "❌ SSH key not found at $key_path."
    read -p "Would you like to generate a new key pair now? [y/n] " input
    if [[ "$input" != "Y" && "$input" != "y" ]]; then
        echo "Cannot proceed without an SSH key. Exiting."
        exit 1
    fi
    echo "Generating a new 2048-bit RSA key pair..."
    mkdir -p "$(dirname "$key_path")"
    ssh-keygen -t rsa -b 2048 -f "$key_path" -N ""
    if [ $? -ne 0 ]; then echo "Key generation failed. Exiting."; exit 1; fi
    echo "✅ Key pair successfully generated."
    echo ""
    echo "--- IMPORTANT: MANUAL ACTION REQUIRED ---"
    echo "You must now add the public key to your EC2 instance."
    echo "1. Log into your EC2 instance using your existing method."
    echo "2. Run the following command on the EC2 instance:"
    echo "   echo '$(cat "$pub_key_path")' >> ~/.ssh/authorized_keys"
    echo "3. Ensure permissions are correct by running:"
    echo "   chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
    echo "-----------------------------------------"
    echo "The script will now exit. Please run it again after adding the key."
    exit 1
}

install_splunk_enterprise() {
    echo "Please select which Splunk package to install:"
    i=0; for v in "${SPLUNK_VERSIONS[@]}"; do echo "  $i) $v"; ((i++)); done
    read -p "Enter selection (0-$((${#SPLUNK_VERSIONS[@]}-1))): " version_nr
    if ! [[ "$version_nr" =~ ^[0-9]+$ ]] || [ "$version_nr" -ge "${#SPLUNK_VERSIONS[@]}" ]; then echo "Invalid selection."; return; fi
    selected_filename=${SPLUNK_FILENAMES[$version_nr]}; selected_url=${SPLUNK_URLS[$version_nr]}
    echo "Preparing to install ${SPLUNK_VERSIONS[$version_nr]} on $HOST..."
    download_cmd="wget -O ${selected_filename} '${selected_url}'"
    install_cmd="sudo rpm -i ${selected_filename}"
    
    # We use printf %q to safely escape any special characters in the password.
    start_cmd="sudo /opt/splunk/bin/splunk start"
    
    enable_boot_start_cmd="sudo /opt/splunk/bin/splunk enable boot-start -systemd-managed 1 -user splunk --accept-license --seed-passwd $(printf %q "$SPLUNK_ADMIN_PASS")"
    
    ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$download_cmd"
    ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$install_cmd"
    ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$CHOWN_SPLUNK_FULL"
    
    echo "Enabeling systemd boot start and setting admin password..."
    ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$enable_boot_start_cmd"
    
    echo "Starting Splunk for the first time"
    ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$start_cmd"
    
    echo "Splunk Enterprise installation and initial configuration complete."
}

install_license() {
    echo "Searching for license files in $SPLUNK_DOWNLOADS_PATH..."
    licenses=()
    while IFS= read -r -d $'\0' file; do licenses+=("$file"); done < <(find "$SPLUNK_DOWNLOADS_PATH" -maxdepth 1 \( -name "*.lic" -o -name "*.License" -o -name "*.license" \) -print0 | sort -z)
    if [ ${#licenses[@]} -eq 0 ]; then echo "No license files found to install."; return; fi

    while true; do
        if [ ${#licenses[@]} -eq 0 ]; then echo "All available licenses have been installed."; break; fi
        echo "Please select a license to install:"; i=0
        for license in "${licenses[@]}"; do echo "  $i) ${license##*/}"; ((i++)); done
        echo "  q) Quit license installation"
        read -p "Enter selection (0-$((${#licenses[@]}-1)) or q to quit: " selection
        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then echo "Finished installing licenses."; break; fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge "${#licenses[@]}" ]; then echo "Invalid selection."; continue; fi

        selected_license_path=${licenses[$selection]}
        license_filename=${selected_license_path##*/}
        license_basename="${license_filename%.*}"
        new_license_filename="${license_basename}.lic"
        sanitized_new_filename="${new_license_filename// /_}"
        remote_license_path="/opt/splunk/etc/licenses/$(printf %q "$sanitized_new_filename")"

        echo "1. Copying $license_filename to the server..."
        scp -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' "$selected_license_path" $USER@$HOST:/home/$USER/
        echo "2. Moving and renaming license on server..."
        move_cmd="sudo mv /home/$USER/$(printf %q "$license_filename") $remote_license_path"
        ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$move_cmd"
        echo "3. Setting ownership for the new license..."
        chown_cmd="sudo chown splunk:splunk $remote_license_path"
        ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$chown_cmd"
        
        echo "4. Adding license to Splunk instance..."
        add_license_cmd="sudo -u splunk /opt/splunk/bin/splunk add licenses $remote_license_path ${AUTH_FLAG}"
        ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$add_license_cmd"

        echo "Installation of ${license_filename} complete. Added as ${sanitized_new_filename} on server."
        echo "----------------------------------------"
        licenses=("${licenses[@]:0:$selection}" "${licenses[@]:$((selection + 1))}")
    done
    echo "A Splunk restart may be required to apply new licenses."
}


# --- Main Script Logic ---
clear
print_header
check_and_setup_ssh_key
echo "----------------------------------------"
echo "Please add the public IP of your EC2 instance"
read HOST
echo "Target IP: $HOST"; echo "Target User: $USER"
echo "----------------------------------------"

echo "Please provide the Splunk admin credentials to be set on the remote host."
read -p "Enter Splunk Admin Username [admin]: " SPLUNK_ADMIN_USER
SPLUNK_ADMIN_USER=${SPLUNK_ADMIN_USER:-admin}
read -s -p "Enter new Splunk Admin Password: " SPLUNK_ADMIN_PASS
echo "" # Add a newline after the silent password prompt
AUTH_FLAG="-auth ${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASS}"
echo "----------------------------------------"

echo "Install Splunk Enterprise? [y/n]"; read input
if [[ $input == "Y" || $input == "y" ]]; then install_splunk_enterprise; fi
echo "----------------------------------------"
install_license
echo "----------------------------------------"
echo "Install Java ($JAVA_PACKAGE)? [y/n]"; read input
if [[ $input == "Y" || $input == "y" ]]; then
   ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$SUDO_DNF_UPDATE"
   ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$SUDO_INSTALL_JAVA"
else
   echo "Skipping Java installation."
fi
echo "----------------------------------------"
echo "Searching for Splunk App packages in $SPLUNK_DOWNLOADS_PATH"
packages=()
while IFS= read -r -d $'\0' file; do packages+=("$file"); done < <(find "$SPLUNK_DOWNLOADS_PATH" -maxdepth 1 -name "*.spl" -print0 | sort -z)
if [ ${#packages[@]} -eq 0 ]; then echo "No .spl files found in $SPLUNK_DOWNLOADS_PATH."; fi

while true; do
   echo "--- Splunk App Management ---"
   if [ ${#packages[@]} -gt 0 ]; then
       echo "Please select a Splunk App package to install:"; i=0
       for package in "${packages[@]}"; do echo "  $i) ${package##*/}"; ((i++)); done
       echo "  -------------------------------------"
   fi
   echo "  r) Restart Splunk on the remote host"; echo "  q) Quit"
   read -p "Enter your choice: " selection
   if [[ "$selection" == "q" || "$selection" == "Q" ]]; then echo "Exiting."; break; fi
   if [[ "$selection" == "r" || "$selection" == "R" ]]; then
       ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$RESTART_SPLUNK"
       echo "Splunk restart command sent."
       ssh -i $DEF_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$SPLUNKD_STATUS"; continue
   fi
   if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -ge "${#packages[@]}" ]; then echo "Invalid."; continue; fi

   selected_package_path=${packages[$selection]}
   package_name=${selected_package_path##*/}

   echo "Copying $package_name to the server..."
   scp -i $DEF_KEY -r -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' "$selected_package_path" $USER@$HOST:/home/$USER/
   
   echo "Untarring $package_name on the server..." 
   untar_package="sudo tar -xvzf /home/$USER/$(printf %q "$package_name") -C /opt/splunk/etc/apps/"
   ssh -i $DEF_KEY  -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$untar_package"
   
   echo "Setting ownership for Splunk app..."
   ssh -i $DEF_KEY  -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' $USER@$HOST "$CHOWN_SPLUNK_APPS"
   
   echo "Installation of $package_name complete."
   echo "----------------------------------------"
done