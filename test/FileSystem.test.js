const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("FileSystem Contract", function () {
  let fileSystem;
  let owner;
  let addr1;

  beforeEach(async function () {
    [owner, addr1] = await ethers.getSigners();
    const FileSystem = await ethers.getContractFactory("FileSystem");
    fileSystem = await FileSystem.deploy();
    await fileSystem.waitForDeployment();
  });

  describe("File Operations", function () {
    it("Should create a file", async function () {
      const path = "test.txt";
      const content = ethers.toUtf8Bytes("Hello, World!");

      await fileSystem.createFile(path, content);

      const [name, entryType, ownerAddr, fileContent, timestamp, exists] = 
        await fileSystem.getEntry(owner.address, path);

      expect(exists).to.be.true;
      expect(name).to.equal(path);
      expect(entryType).to.equal(0); // FILE
      expect(ownerAddr).to.equal(owner.address);
      expect(ethers.toUtf8String(fileContent)).to.equal("Hello, World!");
    });

    it("Should update a file", async function () {
      const path = "test.txt";
      const content1 = ethers.toUtf8Bytes("Hello");
      const content2 = ethers.toUtf8Bytes("World");

      await fileSystem.createFile(path, content1);
      await fileSystem.updateFile(path, content2);

      const [, , , fileContent] = await fileSystem.getEntry(owner.address, path);
      expect(ethers.toUtf8String(fileContent)).to.equal("World");
    });

    it("Should not allow creating duplicate files", async function () {
      const path = "test.txt";
      const content = ethers.toUtf8Bytes("Test");

      await fileSystem.createFile(path, content);
      await expect(
        fileSystem.createFile(path, content)
      ).to.be.revertedWith("Entry already exists");
    });
  });

  describe("Directory Operations", function () {
    it("Should create a directory", async function () {
      const path = "mydir";

      await fileSystem.createDirectory(path);

      const [name, entryType, ownerAddr, , , exists] = 
        await fileSystem.getEntry(owner.address, path);

      expect(exists).to.be.true;
      expect(name).to.equal(path);
      expect(entryType).to.equal(1); // DIRECTORY
      expect(ownerAddr).to.equal(owner.address);
    });
  });

  describe("Delete Operations", function () {
    it("Should delete a file", async function () {
      const path = "test.txt";
      const content = ethers.toUtf8Bytes("Test");

      await fileSystem.createFile(path, content);
      await fileSystem.deleteEntry(path);

      const [, , , , , exists] = await fileSystem.getEntry(owner.address, path);
      expect(exists).to.be.false;
    });
  });

  describe("Account Paths", function () {
    it("Should list all paths for an account", async function () {
      await fileSystem.createFile("file1.txt", ethers.toUtf8Bytes("1"));
      await fileSystem.createFile("file2.txt", ethers.toUtf8Bytes("2"));
      await fileSystem.createDirectory("dir1");

      const paths = await fileSystem.getAccountPaths(owner.address);
      expect(paths.length).to.equal(3);
      expect(paths).to.include("file1.txt");
      expect(paths).to.include("file2.txt");
      expect(paths).to.include("dir1");
    });
  });

  describe("Access Control", function () {
    it("Should only allow owner to update file", async function () {
      const path = "test.txt";
      const content = ethers.toUtf8Bytes("Test");

      await fileSystem.createFile(path, content);
      
      await expect(
        fileSystem.connect(addr1).updateFile(path, ethers.toUtf8Bytes("New"))
      ).to.be.revertedWith("Not owner");
    });

    it("Should only allow owner to delete file", async function () {
      const path = "test.txt";
      const content = ethers.toUtf8Bytes("Test");

      await fileSystem.createFile(path, content);
      
      await expect(
        fileSystem.connect(addr1).deleteEntry(path)
      ).to.be.revertedWith("Not owner");
    });
  });
});
