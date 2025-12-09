# Quick Start Guide

This guide will help you get fuse-eth-fs up and running quickly.

## 1. Installation

```bash
# Install Python dependencies
pip install -r requirements.txt

# Install Node.js dependencies
npm install
```

## 2. Start Local Blockchain

In one terminal, start a local Hardhat node:

```bash
npx hardhat node
```

Keep this running. You should see output like:
```
Started HTTP and WebSocket JSON-RPC server at http://127.0.0.1:8545/
```

## 3. Deploy Smart Contract

In a new terminal, deploy the FileSystem contract:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

You should see:
```
FileSystem deployed to: 0x5FbDB2315678afecb367f032d93F642f64180aa3
Deployment info saved to deployment.json
```

## 4. Configure Environment

Copy the example environment file:

```bash
cp .env.example .env
```

The default values should work with the local Hardhat node.

## 5. Create Mount Point

```bash
mkdir -p /tmp/ethfs
```

## 6. Mount the Filesystem

```bash
python -m fuse_eth_fs.main /tmp/ethfs --foreground --debug
```

Or if you installed the package:

```bash
fuse-eth-fs /tmp/ethfs --foreground --debug
```

## 7. Use the Filesystem

In another terminal:

```bash
# Navigate to the mounted filesystem
cd /tmp/ethfs

# List chain IDs
ls -la
# You should see: 1337 (the Hardhat local chain ID)

# Navigate to your account directory
# The default Hardhat account is 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
cd 1337/0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266/

# Create a file
echo "Hello from the blockchain!" > hello.txt

# Read the file
cat hello.txt

# Create a directory
mkdir documents

# Create a file in the directory
echo "My blockchain document" > documents/readme.txt

# List all files
ls -la

# Read the nested file
cat documents/readme.txt

# Delete a file
rm hello.txt
```

## 8. View on Blockchain

You can verify your files are on the blockchain by checking the contract directly:

```bash
# In a new terminal with the Hardhat console
npx hardhat console --network localhost
```

Then in the console:
```javascript
const FileSystem = await ethers.getContractFactory("FileSystem");
const fs = await FileSystem.attach("0x5FbDB2315678afecb367f032d93F642f64180aa3");
const account = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const paths = await fs.getAccountPaths(account);
console.log(paths);
```

## 9. Unmount

To unmount the filesystem, press `Ctrl+C` in the terminal where fuse-eth-fs is running.

## Troubleshooting

### "fusermount: failed to open /etc/fuse.conf"
This is usually harmless. The filesystem should still work.

### "Transport Error"
Make sure the Hardhat node is running and the RPC_URL in .env is correct.

### "No contract addresses specified"
Make sure deployment.json exists or set CONTRACT_ADDRESS in .env.

### Permission errors when mounting
Try running without `allow_other` option (default behavior).

## Next Steps

- Explore the code in `fuse_eth_fs/`
- Modify the smart contract in `contracts/FileSystem.sol`
- Connect to other networks by changing RPC_URL
- Deploy to testnets like Sepolia or Goerli
