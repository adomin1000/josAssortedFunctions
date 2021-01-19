Configuration HyperVForMSIX {
    Import-DscResource -ModuleName PsDesiredStateConfiguration


    Node 'localhost' {

        WindowsFeature Microsoft-Hyper-V {

            Ensure = "Present"

            Name   = "Hyper-V"

        }
    }

}