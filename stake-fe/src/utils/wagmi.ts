import { getDefaultConfig } from '@rainbow-me/rainbowkit';
import { http } from 'viem';
import {
  mainnet, sepolia, hardhat,
} from 'wagmi/chains';
// from https://cloud.walletconnect.com/
const ProjectId = 'e3242412afd6123ce1dda1de23a8c016'

export const config = getDefaultConfig({
  appName: 'Meta Node Stake',
  projectId: ProjectId,
  chains: [
    hardhat, sepolia
  ],
  transports: {
    // 添加本地RPC
    [hardhat.id]: http('http://127.0.0.1:8545'),
    // 替换之前 不可用的 https://rpc.sepolia.org/
    [sepolia.id]: http('https://sepolia.infura.io/v3/d8ed0bd1de8242d998a1405b6932ab33')
  },
  ssr: true,
});

export const defaultChainId: number = sepolia.id