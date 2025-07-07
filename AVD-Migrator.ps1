# Login to Azure
Connect-AzAccount
$scriptStartTime = Get-Date
Write-Output "Script started at: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

# Define variables
$Source_subscription_Id = "source_sub_id" # Replace with your actual source subscription ID
$Destination_subscription_Id = "destination_sub_id" # Replace with your actual destination subscription ID
$SourcevmResourceGroupName = "source_sessionhosts_rg" # Replace with your sessionhosts source resource group name
$DestinationvmResourceGroupName= "destination_sessionhosts_rg"  # Replace with your sessionhosts destination resource group name
$galleryName = "gallery_name" # Replace with your gallery name
$galleryResourceGroupName = "compute_gallery_rg" # Replace with your gallery resource group name
$imageDefinitionName = "image_definition_name" # Replace with your image definition name
$location = "region_name" # Replace with your region name
$DestHPresourceGroupName = "destination_hostpool_rg" # Replace with your destination hostpool resource group name
$DesthostPoolName = "destination_hostpool_name" # Replace with your destination host pool name
$SourceHostPoolName = "source_hostpool_name" # Replace with your source host pool name
$vnetName = "destination_vnet_name" # Replace with your destination VNET name
$vnetrg = "destination_vnet_rg" # Replace with your destination VNET resource group name
# Obtain destination hostpool RdsRegistrationInfotoken - valid for 12 hours
Set-AzContext -Subscription $Destination_subscription_Id -ErrorAction SilentlyContinue | Out-Null
$Registered = Get-AzWvdRegistrationInfo -SubscriptionId $Destination_subscription_Id -ResourceGroupName $DestHPresourceGroupName -HostPoolName $DesthostPoolName
if (-not(-Not $Registered.Token)){$registrationTokenValidFor = (NEW-TIMESPAN -Start (get-date) -End $Registered.ExpirationTime | select Days,Hours,Minutes,Seconds)}
$registrationTokenValidFor
if ((-Not $Registered.Token) -or ($Registered.ExpirationTime -le (get-date)))
{
    $Registered = New-AzWvdRegistrationInfo -SubscriptionId $Destination_subscription_Id -ResourceGroupName $DestHPresourceGroupName -HostPoolName $DesthostPoolName -ExpirationTime (Get-Date).AddHours(12) -ErrorAction SilentlyContinue
}
$registrationToken = $Registered.Token

Set-AzContext -Subscription $Source_subscription_Id -ErrorAction SilentlyContinue | Out-Null
# retrieve all VM's in the source resource group
$vmList = Get-AzVM -ResourceGroupName $SourcevmResourceGroupName
$successfulMigrations = @()

foreach ($vm in $vmList) {
    $migrationSuccess = $false
    try {
        Set-AzContext -Subscription $Source_subscription_Id
        $vmName = $vm.Name
        Write-Output "Starting migration for VM: $vmName"
    # Extract the number from the VM name to use in the image version
    $vmNumber = $vmName -replace '\D', ''

    # Set additional variables
    $imageVersion = "1.0.$vmNumber"

    # Get vm and set regional properties
    $vm_obj = Get-AzVM -ResourceGroupName $SourcevmResourceGroupName -Name $vmName
    $region1 = @{Name=$location;ReplicaCount=1}
    $targetRegions = @($region1)

    Set-AzContext -Subscription $Source_subscription_Id -ErrorAction SilentlyContinue | Out-Null

    #Capture the specialized image
    try {

    Write-output "Stopping & Capturing a VM image from $vmName. This will take about 10 minutes"
    Stop-AzVM -ResourceGroupName $SourcevmResourceGroupName -Name $vmName -Force
    New-AzGalleryImageVersion -GalleryImageDefinitionName $imageDefinitionName -GalleryImageVersionName $imageVersion -GalleryName $galleryName -ResourceGroupName $galleryResourceGroupName -Location $location -TargetRegion $targetRegions -SourceImageVMId $vm_obj.Id.ToString() #-PublishingProfileEndOfLifeDate '2030-12-01'
    $image = Get-AzGalleryImageVersion -ResourceGroupName $galleryResourceGroupName -GalleryName $galleryName -GalleryImageDefinitionName $imageDefinitionName -GalleryImageVersionName $imageVersion
    Write-output "VM Image created succesfully"

    } catch {
        Write-Output "Failed capturing image: $_"
        Write-Output "Skipping to next VM..."
        continue
    }

    Set-AzContext -Subscription $Destination_subscription_Id -ErrorAction SilentlyContinue | Out-Null
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $vnetrg

    # Create a new NIC
    Write-output "Re-Deploying VM $vmname in $DestinationvmResourceGroupName, in Destination subscription. This will take a few minutes"

    # create a new NIC in destination VNET/Subnet
    try {
    $nic = New-AzNetworkInterface -ResourceGroupName $DestinationvmResourceGroupName -Location $location -Name "$vmName-nic" -SubnetId $vnet.Subnets[0].Id

    # Create a new VM configuration
    Set-AzContext -Subscription $Source_subscription_Id -ErrorAction SilentlyContinue | Out-Null
    $vmConfig = New-AzVMConfig -VMName $vmName -VMSize "Standard_D4ds_v5"
    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $image.Id
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name "osdisk$vmname" -CreateOption FromImage -StorageAccountType "StandardSSD_LRS" 
    $vmConfig.SecurityProfile = @{
        SecurityType = "TrustedLaunch"
    }

    # Create the VM in the destination resource group from the captured image
    Set-AzContext -Subscription $Destination_subscription_Id -ErrorAction SilentlyContinue | Out-Null
    New-AzVM -ResourceGroupName $DestinationvmResourceGroupName -Location $location -VM $vmConfig
    Write-output "VM deployment completed successfully"

    } catch {
        Write-Output "Failed Creating new VM from image: $_"
        Write-Output "Skipping to next VM..."
        continue
    }

    # Register the VM to the destination host pool
    try {
        Write-Output "Registering $vmName to Host Pool $DesthostPoolName"
        Set-AzContext -Subscription $Destination_subscription_Id -ErrorAction SilentlyContinue | Out-Null
 
        $script = @"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -Name "IsRegistered" -Value 0 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\RDInfraAgent" -Name "RegistrationToken" -Value $registrationToken -Force
Restart-Service RDAgentBootLoader
"@

        # Invoke command to register the VM to the host pool
        Invoke-AzVMRunCommand -ResourceGroupName $DestinationvmResourceGroupName -Name $vmName -CommandId 'RunPowerShellScript' -ScriptString $script
        Restart-AzVM -ResourceGroupName $DestinationvmResourceGroupName -Name $vmName
        Write-Output "VM registered to host pool successfully"

        # --- MIGRATE USER ASSIGNMENTS FROM SOURCE HOSTPOOL TO DESTINATION HOSTPOOL ---

        Set-AzContext -Subscription $Source_subscription_Id -ErrorAction SilentlyContinue | Out-Null
        $sourceSessionHostName = $vmName 
        $assignedUser = ($userSessions = Get-AzWvdSessionHost -ResourceGroupName $SourcevmResourceGroupName -HostPoolName $SourceHostPoolName -SessionHostName $sourceSessionHostName).AssignedUser
        if ($assignedUser) {
            Write-Output "Assigning user $assignedUser to $vmName in $DesthostPoolName"
            Set-AzContext -Subscription $Destination_subscription_Id -ErrorAction SilentlyContinue | Out-Null
            Update-AzWvdSessionHost -ResourceGroupName $DestHPresourceGroupName -HostPoolName $DestHostPoolName -SessionHostName $vmName -AssignedUser $assignedUser
        } else {
            Write-Output "No user sessions found for $sourceSessionHostName in $SourceHostPoolName."
        }
        
        # Mark migration as successful
        $migrationSuccess = $true
        $successfulMigrations += $vmName
        Write-Output "Migration completed successfully for $vmName"
        
    } catch {
        Write-Output "Failed registering VM or migrating users: $_"
        Write-Output "Skipping to next VM..."
        continue
    }
        
    } catch {
        Write-Output "Migration failed for $vmName`: $_"
        continue
    }
}

# Delete successfully migrated VMs from source subscription
$scriptEndTime = Get-Date
$totalRuntime = New-TimeSpan -Start $scriptStartTime -End $scriptEndTime
Write-Output "Migration Summary: $($successfulMigrations.Count) out of $($vmList.Count) VMs migrated successfully"
Write-Output "Total script runtime: $($totalRuntime.Hours)h $($totalRuntime.Minutes)m $($totalRuntime.Seconds)s"
Write-Output "Script completed at: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
if ($successfulMigrations.Count -gt 0) {
    Write-Output "Successfully migrated VMs: $($successfulMigrations -join ', ')"

    # Comment the section below if you don't want to delete source VMs after successful migration
    Write-Output "Deleting source VMs for successfully migrated machines..."
    Set-AzContext -Subscription $Source_subscription_Id -ErrorAction SilentlyContinue | Out-Null
    foreach ($vmToDelete in $successfulMigrations) {
        try {
            Write-Output "Deleting source VM: $vmToDelete"
            Remove-AzVM -ResourceGroupName $SourcevmResourceGroupName -Name $vmToDelete -Force | Out-Null
            Write-Output "Successfully deleted source VM: $vmToDelete"
        } catch {
            Write-Output "Failed to delete source VM $vmToDelete`: $_"
        }
    }
}
