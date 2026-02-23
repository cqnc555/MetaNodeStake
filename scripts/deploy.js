const { ethers, upgrades } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("正在使用账户部署合约:", deployer.address);
    console.log("账户余额:", (await ethers.provider.getBalance(deployer.address)).toString());

    // 1. 部署 MetaNode 奖励代币
    console.log("\n--- 开始部署 MetaNodeToken ---");
    const MetaNodeToken = await ethers.getContractFactory('MetaNodeToken');
    const metaNodeToken = await MetaNodeToken.deploy();
    await metaNodeToken.waitForDeployment();
    const metaNodeTokenAddress = await metaNodeToken.getAddress();
    console.log("MetaNodeToken 部署地址:", metaNodeTokenAddress);

    // 2. 部署 MetaNodeStake (可升级代理合约)
    console.log("\n--- 开始部署 MetaNodeStake 代理合约 ---");
    const MetaNodeStake = await ethers.getContractFactory("MetaNodeStake");

    // 设置初始化参数
    const startBlock = 1; // 替换为实际起始区块
    const endBlock = 999999999999; // 替换为实际结束区块
    const metaNodePerBlock = ethers.parseUnits("1", 18); // 每区块奖励 1 个 MetaNode

    const stake = await upgrades.deployProxy(
        MetaNodeStake,
        [metaNodeTokenAddress, startBlock, endBlock, metaNodePerBlock],
        { initializer: "initialize" }
    );

    await stake.waitForDeployment();
    const stakeAddress = await stake.getAddress();
    console.log("MetaNodeStake 部署地址:", stakeAddress);

    // 3. 将奖励代币注入质押合约池
    console.log("\n--- 开始为质押合约注入奖励代币 ---");
    const tokenAmount = await metaNodeToken.balanceOf(deployer.address);
    const tx = await metaNodeToken.connect(deployer).transfer(stakeAddress, tokenAmount);
    await tx.wait();
    console.log(`成功将 ${ethers.formatUnits(tokenAmount, 18)} 枚 MetaNode 转移至质押合约`);
    console.log("🎉 部署流程全部完成！");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });