// hardhat.config.js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
require("@openzeppelin/hardhat-upgrades");

module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true, // 建议开启优化以节省 Gas
        runs: 200,
      },
    },
  },
  networks: {
    // sepolia: {
    //   url: "https://eth-sepolia.g.alchemy.com/v2/" + process.env.ALCHEMY_API_KEY,
    //   accounts: [process.env.PRIVATE_KEY],
    //   // gasPrice: 30000000000, // 可以先注释掉，让网络自动计算 Gas
    // },
    // 添加一个本地网络配置方便测试
    localhost: {
      url: "http://127.0.0.1:8545"
    }
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
};