// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {FileSystem} from "../contracts/FileSystem.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract DeployScript is Script {
    using stdJson for string;

    function run() external {
        console.log("Deploying FileSystem contract...");

        // Deploy the contract
        FileSystem fileSystem = new FileSystem();
        address deployedAddress = address(fileSystem);
        
        console.log("FileSystem deployed to:", deployedAddress);

        // Get chain ID
        uint256 chainId = block.chainid;
        console.log("Chain ID:", chainId);

        // Get deployment timestamp
        uint256 timestamp = block.timestamp;

        // Create JSON object - serialize each field
        // The jsonKey "deployment" identifies the root object
        string memory jsonKey = "deployment";
        jsonKey.serialize("address", deployedAddress);
        
        // Convert chainId to string to match original format
        string memory chainIdStr = vm.toString(chainId);
        jsonKey.serialize("chainId", chainIdStr);
        
        // Convert timestamp to string (Unix timestamp as string)
        // Note: Original script used ISO string format, but Solidity doesn't have easy date formatting
        // Writing as Unix timestamp string - Python client can convert to ISO if needed
        string memory timestampStr = vm.toString(timestamp);
        string memory json = jsonKey.serialize("deployedAt", timestampStr);

        // Write to deployment.json
        json.write("./deployment.json");

        console.log("Deployment info saved to deployment.json");
        console.log("Address:", deployedAddress);
        console.log("Chain ID:", chainId);
        console.log("Timestamp:", timestamp);
    }
}

