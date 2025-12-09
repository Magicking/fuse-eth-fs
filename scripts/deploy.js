const hre = require("hardhat");

async function main() {
  console.log("Deploying FileSystem contract...");

  const FileSystem = await hre.ethers.getContractFactory("FileSystem");
  const fileSystem = await FileSystem.deploy();

  await fileSystem.waitForDeployment();

  const address = await fileSystem.getAddress();
  console.log("FileSystem deployed to:", address);

  // Save deployment info
  const fs = require('fs');
  const deploymentInfo = {
    address: address,
    chainId: (await hre.ethers.provider.getNetwork()).chainId.toString(),
    deployedAt: new Date().toISOString()
  };

  fs.writeFileSync(
    'deployment.json',
    JSON.stringify(deploymentInfo, null, 2)
  );
  console.log("Deployment info saved to deployment.json");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
