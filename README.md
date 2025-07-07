# AVD-Migrator

Moving Azure Virtual Desktop (AVD) session hosts between subscriptions isn’t a built-in feature of Azure, but it’s a common need for many customers. This PowerShell script automates the entire process end-to-end, including image capture, redeployment, host registration, user assignment migration, and finally, the removal of the old VMs. It enables you to migrate entire Personal Host Pools — along with all user applications, customizations, and local files — across Subscriptions, Regions, and VNets.

<img src="images/avd_migrator.png" alt="Logo" width="300"/>

### Test the script in a test hostpool/environment to understand and validate how it works! ###

---

## Script Breakdown

The script automates the migration of Azure Virtual Desktop Personal session hosts from a source subscription to a destination subscription.

- Captures specialized images of all VMs in the source resource group into a Compute Gallery
- Deploys new VMs in the destination subscription from those images
- Creates new NICs and attaches them to a predefined destination VNet
- Registers the new VMs to a destination AVD Host Pool using a fresh registration token
- Migrates user assignments from the source Host Pool to the destination
- Deletes the original VM from the source environment.  
  *(This step is optional and can be commented out)*

---

## Prerequisites & Considerations

You need to create an Azure Compute Gallery in the Source subscription and a specialized Image definition with the following properties:

- **OS Type:** Windows
- **Image Configuration type:** Specialized
- **VM Generation:** V2
- **Publisher / Offer / SKU:** just provide any string

Also required:

- Destination resource group, VNet and a Host Pool
- The user / identity running this script must have proper RBAC permissions in both source and destination subscriptions (Owner on subs or resource groups will be best).

---

### Other considerations:

- This script assumes your session host names end with a digit — which is the default behaviour (I’ve personally never seen one that doesn’t). That digit is used to generate the image version for each VM. For example, AVD-VM-25 becomes image version 1.0.25.

- It also assumes you're using Trusted Launch VMs. If you're not, you can adjust that setting in the `$vmConfig` part.

- The script is currently set up for a single region, but you can modify it to support multiple regions if needed.

- **Important:** If you plan to run the script multiple times across different host pools, make sure to increment the `$imageVersion` (e.g., use `1.1.$vmNumber`) to avoid naming conflicts. If you reuse the same version number, the script will fail since the image name already exists.

- Each VM is imaged individually, effectively serving as a backup. Once you confirm the migration is successful, you can safely delete those images — though the script doesn’t do this automatically, as a safety measure.

- Migration takes about 15 minutes per VM. The process runs sequentially (no parallelism yet), but I may consider looking into parallel execution in a future update if there's demand.

- Lastly, this script was designed with personal host pools in mind. While you can technically use it to migrate pooled session hosts (just remove the user assignment logic), I haven’t tested that scenario.

### How to use it:

Just copy the script to your IDE and update all key variables.
Once completed run the script and connect to your tenant - It will then start the migration process according to the key variables you provided.
