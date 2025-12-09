from setuptools import setup, find_packages

setup(
    name="fuse-eth-fs",
    version="0.1.0",
    description="A FUSE filesystem backed by Ethereum smart contracts",
    author="",
    author_email="",
    packages=find_packages(),
    install_requires=[
        "fuse-python>=1.0.0",
        "web3>=6.0.0",
        "python-dotenv>=1.0.0",
    ],
    entry_points={
        "console_scripts": [
            "fuse-eth-fs=fuse_eth_fs.main:main",
        ],
    },
    python_requires=">=3.8",
)
