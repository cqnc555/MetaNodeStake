import { useMemo } from "react"
import { Abi, Address } from "viem"
import { getContract } from "viem" // 🌟 修改点 1：直接从 viem 引入原生 getContract
import { useChainId, useWalletClient, usePublicClient } from "wagmi" // 🌟 修改点 2：增加引入 usePublicClient
import { StakeContractAddress } from "../utils/env"
import { stakeAbi } from '../assets/abis/stake'

type UseContractOptions = {
  chainId?: number
}

export function useContract<TAbi extends Abi>(
    addressOrAddressMap?: Address | { [chainId: number]: Address },
    abi?: TAbi,
    options?: UseContractOptions,
) {
  const currentChainId = useChainId()
  const chainId = options?.chainId || currentChainId

  // 🌟 修改点 3：同时获取 publicClient (读) 和 walletClient (写)
  const publicClient = usePublicClient({ chainId })
  const { data: walletClient } = useWalletClient({ chainId })

  return useMemo(() => {
    if (!addressOrAddressMap || !abi || !chainId || !publicClient) return null

    let address: Address | undefined
    if (typeof addressOrAddressMap === 'string') {
      address = addressOrAddressMap
    } else {
      address = addressOrAddressMap[chainId]
    }

    if (!address) return null

    try {
      // 🌟 修改点 4：使用 viem 标准格式构造合约实例
      return getContract({
        abi,
        address,
        client: {
          public: publicClient, // 注入读取能力 (开启 .read)
          wallet: walletClient, // 注入写入能力 (开启 .write)
        },
      })
    } catch (error) {
      console.error('Failed to get contract', error)
      return null
    }
  }, [addressOrAddressMap, abi, chainId, publicClient, walletClient])
}

export const useStakeContract = () => {
  return useContract(StakeContractAddress, stakeAbi as Abi)
}