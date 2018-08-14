<#
    .SYNOPSIS
        This Azure Automation runbook speeds up UDR failover in environments with >200 routes by switching routetables associated with subnets rather than
        changing the next hop IP within the route table.
        
    .DESCRIPTION
       This runbook is intended to be triggered by a webhook when the NGF cluster with which it is associated fails over. 

        This is a PowerShell runbook for Service Management mode, it requires the Azure module

        This runbook requires the "Azure" module which are present by default in Azure Automation accounts.

    .PARAMETER WebhookData
        The JSON data that is passed in via the webhook call within this data the following parameters are expected
        SubscriptionId
            Provides the Subscription ID that we are working in
        id
            Provides the Virtual Network name that the routes are located in.
        OldNextHopIP
            This is generated by the NGF and is the IP of the cluster node that was previously taking the traffic.
        NewNextHopIP
            This is generated by the NGF config and is the IP that is now running active
        
    .PARAMETER testmode
            If $true, the runbook will not perform any power actions and will only simulate evaluating the tagged schedules. Use this
            to test your runbook to see what it will do when run normally (Simulate = $false).
		.NOTES
                AUTHOR: Gemma Allen (gallen@barracuda.com)
                LASTEDIT: 14 August 2018
                v1 created to update route tables in ASM
#>
 param(
    [object]$WebhookData
    )
    #This script is in test mode by default, remove the leading # to comment out lines 22,23 & 24. 
	#fill in the details for the webhookbody with your test data if you are not using the webhook
    #<#
    $testmode = $true
    $webhookData = "data"
    $nowebhook = $true
    #>

#Define the identifiers that allow the script to decide which routes to associate and disassociate.
#Define the primary node IP
$primarynodeIP = "10.9.0.4"
#Provide the suffix that will be appended to any routes associates to the second FW instance. So a route called route_1 would become route_1_B
$route_suffix = "_B"


    if($webhookData -ne $null){
            
# Collect properties of WebhookData.
        Write-Output $WebHookData

        $WebhookName    =   $WebhookData.WebhookName
        $WebhookBody    =   $WebhookData.RequestBody
        $WebhookHeaders =   $WebhookData.RequestHeader

        # Outputs information on the webhook name that called This
        Write-Output "This runbook was started from webhook $WebhookName."
         if($nowebhook){
         #The below can be edited to replicate your NGF's IP's and subscription details 
         #it doesn't need commenting out as the section under line #18 enables this
          $WebhookBody = '[
{ 
"SubscriptionId" : "31de56f1-2378-43ae-bdf7-2c229adf2f7f",
"id": "Group GA-NE-CLASSIC-RG GA-NE-CLASSIC-VNET",
"properties" :{
	"OldNextHopIP" :  "10.9.0.5",
	"NewNextHopIP" : "10.9.0.4"
}
}
]'

}

        # Obtain the WebhookBody containing the data to change
        try{

#When testing without the NGF you can fill in the below and uncomment the second ConvertedJson line to test
           
            Write-Output "`nWEBHOOK BODY IN"
            Write-Output "============="
            Write-Output $WebhookBody

            if($nowebhook){
			    #The below line is used in combination with the Webhookbody variable commented out.
			    $ConvertedJson = ConvertFrom-Json -InputObject $WebhookBody
            }else{
			    #I'm sure there's a better way, but this works. As it's JSON in JSON I had double convert from the body. 
                $ConvertedJson = ConvertFrom-Json -InputObject (ConvertFrom-Json -InputObject $WebhookBody)
            }
            Write-Output "`nWEBHOOK BODY OUT"
            Write-Output "============="
            Write-Output $ConvertedJson
            Write-Output "JSON Sub" $ConvertedJson.SubscriptionId
			if($ConvertedJson.SubscriptionId -eq "secondnic"){Write-Output "Script triggered on behalf of second NIC will act upon all Subs"}

        }catch{
            if (!$ConvertedJson)
            {
                Write-Error -Message $_.Exception
                $ErrorMessage = "No body found."
                throw $ErrorMessage
            } else{
                Write-Error -Message $_.Exception
                throw $_.Exception
            }
        }

#This is created automatically in a Automation account, but if you wish you can create another
    $ConnectionAssetName = "AzureClassicRunAsConnection"

    # Get the connection
    $connection = Get-AutomationConnection -Name $connectionAssetName        

    # Authenticate to Azure with certificate
    Write-Verbose "Get connection asset: $ConnectionAssetName" -Verbose
    $Conn = Get-AutomationConnection -Name $ConnectionAssetName
    if ($Conn -eq $null)
    {
        throw "Could not retrieve connection asset: $ConnectionAssetName. Assure that this asset exists in the Automation account."
    }

    $CertificateAssetName = $Conn.CertificateAssetName
    Write-Verbose "Getting the certificate: $CertificateAssetName" -Verbose
    $AzureCert = Get-AutomationCertificate -Name $CertificateAssetName
    if ($AzureCert -eq $null)
    {
        throw "Could not retrieve certificate asset: $CertificateAssetName. Assure that this asset exists in the Automation account."
    }

    Write-Verbose "Authenticating to Azure with certificate." -Verbose
    Set-AzureSubscription -SubscriptionName $Conn.SubscriptionName -SubscriptionId $Conn.SubscriptionID -Certificate $AzureCert 
    Select-AzureSubscription -SubscriptionId $Conn.SubscriptionID

    #Collects the vNET Name from the webhook uses the spare ID field to provide this
    $vnetName = $ConvertedJson.id

    #Get Values required for later.
    #Collects the configuration of the working VNET
    $vnetConfig = Get-AzureVNetSite -VNetName "$($vnetName)"

	#Get's NGF's local subscription and NextHopIP's
        $nexthopip = ($ConvertedJson | Where -Property SubscriptionId -eq $ConvertedJson.SubscriptionId | Select-Object -ExpandProperty Properties).NewNextHopIP
        $oldnexthopip = ($ConvertedJson | Where -Property SubscriptionId -eq $ConvertedJson.SubscriptionId | Select-Object -ExpandProperty Properties).OldNextHopIP
        Write-Verbose "Old Hop IP: $($oldnexthopIP) " -Verbose
        Write-Verbose "Next Hop IP: $($nexthopIP) " -Verbose
        Write-Verbose "Primary NGF IP: $($primarynodeIP)" -Verbose

    #This loops through the subnets in the VNET config and switches between none and suffixed route tables.
    if($nexthopip){
        ForEach($subnet in $vnetConfig.Subnets){
            Write-Verbose "Checking Subnet $($subnet.Name) for routes" -Verbose
            
            if(Get-AzureSubnetRouteTable -VirtualNetworkName $vnetName -SubnetName $subnet.Name -WarningAction SilentlyContinue -ErrorAction SilentlyContinue){
                
                $route = Get-AzureSubnetRouteTable -VirtualNetworkName $vnetName -SubnetName $subnet.Name
                $routetable = Get-AzureRouteTable -Detailed -Name $route.Name
                Write-Verbose "Found routetable $($route.Name) associated with subnet $($subnet.Name)" -Verbose
            
                #If the attached route table contains the oldnexthopIP then we are making the change the right way around
                if($routetable.Routes.NextHop.IpAddress -eq $oldnexthopIP){
                
                #This presumes that the routes for the second NGF end in _B and so if your oldnextHopIP is the primary node, routes should have _B added to their name
                #If the NextHopIP matches the IP identified for the primary node then remove the route_suffix, if they don't match then append the suffix to the existing route name 
                    if($nexthopIP -eq $primarynodeIP){
                        $routeName = ($route.Name).Replace("$route_suffix",'')
                    }else{
                        $routeName = "$($route.Name)$($route_suffix)"
                    }
                #Now check that the new route table exists if it doesn't stop the script.
                    if(Get-AzureRouteTable -Name "$($routeName)"){
                        $stoploop = $false
                        #Removes the existing subnet route table and if this fails retries 3 times with a 10 second pause.
                        $retryloop = 0
                        do{
                            $Error.Clear()
                            $retryloop++;
                            #Once on the 3rd attempt cancel
                            if($retryloop -eq 3){
                                $stoploop = $true; 
                            }
                            try{
                                
                          
                                Write-Verbose "Removing route tables from $($Subnet.Name)" -Verbose
                                if($testmode){
                                    Write-Verbose $retryloop
                                    Write-Verbose "Running in testmode so has not made route table changes at this time" -Verbose 
                                    #As in testmode aborts after one loop
                                    $stoploop = $true;
                                }else{
                                    Remove-AzureSubnetRouteTable -VirtualNetworkName $vnetName -SubnetName $subnet.Name -Force
                                      
                                }
                                
                            }catch{
                                
                                Write-Output("Attempt $($retryloop) : Failed to remove existing route $($routeName) from $($subnet.Name)")
                                if($retryloop -eq 3){ Write-Error "Unable to remove existing route, aborting"-Verbose; $stoploop = $true; }else{$stoploop = $false;}
                                
                            }

                            #If there are no errors then stop the loop
                            if($Error.Count -eq 0){$stoploop = $true;}  
                    
                            Sleep 10
                        }While($stoploop -eq $false)
#*******************************************************************************************************************************************************
                        #Pauses between detaching the previous route and adding a new one - ASM can be slow sometimes
#*******************************************************************************************************************************************************
                        Sleep 10
                        $retryloop = 0

                        do{
                            $Error.Clear()
                            $retryloop++;
                            try{
                                Write-Verbose "Attaching new route $($routeName) onto $($subnet.Name)" -Verbose
                                if($testmode){
                                    Write-Verbose "Running in Simulation mode so not actually making a change" -Verbose
                                }else{
                                    Set-AzureSubnetRouteTable -VirtualNetworkName $vnetName -SubnetName $subnet.Name -RouteTableName "$($routeName)"
                                }
                            }catch{
                                Write-Verbose "Failed to associate new route $($routeName) with $($subnet.Name)" -Verbose
                                $stoploop = $false;
                                if($retryloop -eq 3){ Write-Error "Unable to add new route, aborting" -Verbose; $stoploop = $true; }else{$stoploop = $false;}
                            }
                            #If there are no errors then stop the loop
                            if($Error.Count -eq 0){$stoploop = $true;}  
                        }While($stoploop = $false)
                    }else{
                        Write-Verbose "No $($route_suffix) side route table exists called: $($routeName)" -Verbose
                    }
                }else{
                    Write-Verbose "The currently attached routetable does not contain the Next Hop IP: $($oldnexthopIP)" -Verbose
                }
            }else{
                Write-Verbose "No routetables are associated with subnet: $($subnet.Name)" -Verbose
            }
        }
    }else{#If nexthopip found
        Write-Error -Message "No nexthop IP found in webhook data"
    }
    Write-Output ("Script execution completed")



}else{
    Write-Verbose "No Webhook data found" -Verbose
}