// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MetaNodeStake is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    
    // ================= 定义角色 =================
    // 管理员角色
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // 默认管理员角色
    bytes32 public constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
    // 升级角色
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");

    uint256 public constant ETH_PID = 0;

    // ================= 数据结构 =================
    
    // 解质押请求（提现队列）
    struct UnstakeRequest {
        uint256 amount;       // 申请解绑的金额
        uint256 unlockBlocks; // 解锁的区块高度 (当前区块 + 锁定期)
    }

    // 用户信息
    struct User {
        uint256 stAmount;           // 已质押的数量
        uint256 finishedMetaNode;   // 已经结算/分配的奖励 (Reward Debt)
        uint256 pendingMetaNode;    // 待领取的奖励
        UnstakeRequest[] requests;  // 用户的解绑请求队列
    }

    // 质押池信息
    struct Pool {
        address stTokenAddress;      // 质押代币的合约地址 (如果是 ETH 池可以设为 address(0))
        uint256 poolWeight;          // 池子权重 (决定分发奖励的比例)
        uint256 lastRewardBlock;     // 最后一次计算奖励的区块高度
        uint256 accMetaNodePerST;    // 每单位质押代币累积的奖励 (乘以1e18 防止精度丢失)
        uint256 stTokenAmount;       // 当前池子总质押量
        uint256 minDepositAmount;    // 最小质押门槛
        uint256 unstakeLockedBlocks; // 解绑需要的锁定期（区块数量）
    }


    // ================= 事件 (Events) =================
    event AddPool(address indexed stTokenAddress, uint256 indexed poolWeight, uint256 indexed lastRewardBlock, uint256 minDepositAmount, uint256 unstakeLockedBlocks);
    event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);
    event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolWeight, uint256 totalPoolWeight);
    event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalMetaNode);
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount); 

    // ================= 修饰器 (Modifiers) =================
    // 校验传入的 poolId 是否有效（防止数组越界）
    modifier checkPid(uint256 _pid) {
        require(_pid < pools.length, "invalid pid");
        _;
    }


    // ================= 状态变量 =================
    
    IERC20 public metaNodeToken; // 奖励代币合约实例
    
    uint256 public startBlock;   // 质押开始区块
    uint256 public endBlock;     // 质押结束区块
    uint256 public metaNodePerBlock; // 每个区块产出的总奖励数量
    uint256 public totalPoolWeight;  // 所有池子权重的总和

    Pool[] public pools; // 所有的质押池
    
    // 映射: poolId => userAddress => User 结构
    mapping(uint256 => mapping(address => User)) public users;

    // 防止重入攻击的标识 (更推荐使用 ReentrancyGuardUpgradeable，这里仅作演示)
    bool private _locked;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // 保护逻辑合约不被初始化
    }

    // 初始化函数 (替代传统构造函数)
    function initialize(
        IERC20 _metaNode,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _metaNodePerBlock
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);

        metaNodeToken = _metaNode;
        startBlock = _startBlock;
        endBlock = _endBlock;
        metaNodePerBlock = _metaNodePerBlock;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADE_ROLE)
        override
    {}


    /**
     * @notice 新增一个质押池 (管理员权限)
     * @param _stTokenAddress 质押代币的合约地址 (ETH池填 0x0)
     * @param _poolWeight 该池子分配奖励的权重
     * @param _minDepositAmount 最小质押金额
     * @param _unstakeLockedBlocks 解质押需要的等待区块数
     * @param _withUpdate 是否在添加前结算所有池子的奖励
     */
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        // 核心规则：如果是添加第一个池子，必须是 ETH 池 (地址为 0)
        if (pools.length > 0) {
            require(_stTokenAddress != address(0x0), "invalid staking token address");
        } else {
            require(_stTokenAddress == address(0x0), "invalid staking token address");
        }
        
        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        // 只能在活动期间添加池子
        require(block.number < endBlock, "Already ended");

        // 引入全局更新（占位）：改变资金池数量或权重前，通常需要把过去所有池子产生的奖励结算清楚
        if (_withUpdate) {
            massUpdatePools();
        }

        // 确定该池子的起始计算区块
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        // 累加总权重
        totalPoolWeight = totalPoolWeight + _poolWeight;

        pools.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }


    /**
     * @notice 更新指定池子的配置参数 (门槛、锁定期)
     */
    function updatePoolInfo(
        uint256 _pid,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pools[_pid].minDepositAmount = _minDepositAmount;
        pools[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }


    /**
     * @notice 更新指定池子的奖励分配权重
     * @param _withUpdate 强烈建议传 true，否则会导致历史奖励分配错乱
     */
    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        if (_withUpdate) {
            massUpdatePools();
        }

        // 重新计算全局总权重: 减去旧的，加上新的
        totalPoolWeight = totalPoolWeight - pools[_pid].poolWeight + _poolWeight;
        pools[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }


    /**
     * @notice 结算所有池子的奖励 (注意：这会消耗较多 Gas，不要频繁调用)
     */
    function massUpdatePools() public {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }


    /**
     * @notice 计算从 _from 到 _to 区间内产生的总奖励数量
     * @param _from 开始区块
     * @param _to 结束区块
     */
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block");
        
        // 限制区间在起止区块内
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        
        if (_from >= _to) {
            return 0;
        }

        // 区间区块数 * 每个区块的奖励产出
        multiplier = (_to - _from) * metaNodePerBlock;
    }


    /**
     * @notice 更新指定质押池的奖励状态
     * @param _pid 质押池ID
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pools[_pid];

        // 如果当前区块还没到上一次结算区块，说明没有新奖励产生，直接返回
        if (block.number <= pool_.lastRewardBlock) {
            return;
        }

        // 1. 获取全局在这个时间段内产生的总奖励，并先乘上该池子的权重
        uint256 totalMetaNode = getMultiplier(
            pool_.lastRewardBlock,
            block.number
        ) * pool_.poolWeight;

        // 2. 除以总权重，得出这个池子实际应该分到的 MetaNode 数量
        totalMetaNode = totalMetaNode / totalPoolWeight;

        uint256 stSupply = pool_.stTokenAmount;
        // 只有当池子里有钱质押的时候，才去计算每单位的累计收益
        if (stSupply > 0) {
            // 将奖励放大 1 ether (10^18) 倍以防止精度丢失
            uint256 totalMetaNode_ = totalMetaNode * 1 ether;

            // 奖励 / 总质押量 = 每 1 个质押代币在这个阶段能分到的量
            totalMetaNode_ = totalMetaNode_ / stSupply;

            // 累加到全局的 accMetaNodePerST 变量上
            pool_.accMetaNodePerST += totalMetaNode_;
        }

        // 把池子的时间戳（区块高度）拨到当前
        pool_.lastRewardBlock = block.number;
        
        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }



    /**
     * @notice 查询用户在指定池子当前的未领取收益 (供前端直接调用)
     */
    function pendingMetaNode(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number); 
    }

    /**
     * @notice 根据具体的区块高度预测收益 (核心推导逻辑)
     */
    function pendingMetaNodeByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pools[_pid];
        User storage user_ = users[_pid][_user];
        
        // 拿到当前记录的每单位收益
        uint256 accMetaNodePerST = pool_.accMetaNodePerST; 
        uint256 stSupply = pool_.stTokenAmount;

        // 如果距离上次结算有新的区块产生，我们在内存中模拟累加一下
        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool_.lastRewardBlock,
                _blockNumber
            ); 
            uint256 MetaNodeForPool = (multiplier * pool_.poolWeight) /
                totalPoolWeight; 
            
            // 模拟算出最新的 accMetaNodePerST
            accMetaNodePerST =
                accMetaNodePerST +
                (MetaNodeForPool * (1 ether)) /
                stSupply; 
        }

        // 核心收益公式：(用户本金 * 最新每单位累计收益) - 已经结算过的收益 + 暂存的待领收益
        return
            (user_.stAmount * accMetaNodePerST) /
            (1 ether) - 
            user_.finishedMetaNode + 
            user_.pendingMetaNode; 
    }



    /**
     * @notice 质押以太坊 (原生代币)
     */
    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pools[ETH_PID]; // ETH_PID = 0
        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        ); 
        
        uint256 _amount = msg.value; // 获取用户打入的 ETH 数量
        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is too small"
        ); 
        
        _deposit(ETH_PID, _amount); 
    }

    /**
     * @notice 质押 ERC20 代币
     * @dev 前端在调用此方法前，必须先调用 ERC20 合约的 approve 方法授权
     */
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support ETH staking"); 
        Pool storage pool_ = pools[_pid];
        
        require(
            _amount > pool_.minDepositAmount,
            "deposit amount is too small"
        ); 
        
        // 如果质押数量大于 0，把用户的代币划转到当前智能合约中
        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            ); 
        }

        _deposit(_pid, _amount); 
    }



    /**
     * @notice 内部记账逻辑：处理存款时的收益结算与本金增加
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pools[_pid];
        User storage user_ = users[_pid][msg.sender];

        // 1. 触发全局结算，确保 pool_.accMetaNodePerST 是当前区块的最新值
        updatePool(_pid); 

        // 2. 如果用户之前已经存过钱了，先把之前的收益结算出来，暂存到 pendingMetaNode 中
        if (user_.stAmount > 0) {
            (bool success1, uint256 accST) = user_.stAmount.tryMul(pool_.accMetaNodePerST);
            require(success1, "user stAmount mul overflow");
            
            (success1, accST) = accST.tryDiv(1 ether); // 还原精度
            require(success1, "div 1 ether overflow");

            // 计算出这次新产生的收益 (当前总应得 - 历史已结算负债)
            (bool success2, uint256 pendingMetaNode_) = accST.trySub(user_.finishedMetaNode);
            require(success2, "sub overflow");

            // 将新收益累加到暂存区，等用户主动 Claim 时再发放
            if (pendingMetaNode_ > 0) {
                user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_; 
            }
        }

        // 3. 真正增加用户的本金和池子的总质押量
        if (_amount > 0) {
            user_.stAmount = user_.stAmount + _amount; 
            pool_.stTokenAmount = pool_.stTokenAmount + _amount; 
        }

        // 4. 更新用户的“历史已结算负债 (finishedMetaNode)” （高水位线）
        // 这一步非常关键！基于新的总本金，重新计算他不该拿的历史收益基数。
        (bool success6, uint256 finishedMetaNode) = user_.stAmount.tryMul(pool_.accMetaNodePerST); 
        require(success6, "mul overflow");
        (success6, finishedMetaNode) = finishedMetaNode.tryDiv(1 ether);
        
        user_.finishedMetaNode = finishedMetaNode; 

        emit Deposit(msg.sender, _pid, _amount); 
    }




    // 记得在顶部声明事件
    event RequestUnstake(address indexed user, uint256 indexed poolId, uint256 amount);

    /**
     * @notice 申请解除质押 (将资金放入解锁队列)
     */
    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pools[_pid];
        User storage user_ = users[_pid][msg.sender];

        // 1. 余额校验
        require(user_.stAmount >= _amount, "Not enough staking token balance");

        // 2. 任何涉及到本金变动的操作，必须先结算！
        updatePool(_pid);

        // 3. 计算在本次“减仓”之前，用户赚了多少钱，暂存起来
        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether) -
            user_.finishedMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_;
        }

        // 4. 执行减仓逻辑，并压入提现队列
        if (_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            
            // 当前区块号 + 池子配置的锁定期 = 解锁的具体区块号
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unlockBlocks: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        // 5. 更新池子总负债和用户的已结算高水位线
        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether);

        emit RequestUnstake(msg.sender, _pid, _amount);
    }



    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);

    /**
     * @notice 提取已经度过锁定期的资金
     */
    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pools[_pid];
        User storage user_ = users[_pid][msg.sender];

        uint256 pendingWithdraw_; // 累加这次总共能提取多少钱
        uint256 popNum_;          // 统计有多少个请求可以被删除

        // 1. 遍历请求队列，找出已到期的金额
        for (uint256 i = 0; i < user_.requests.length; i++) {
            // 因为是有序队列，一旦碰到还没到期的，后面的肯定也没到期，直接 break 节省 Gas
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }

        // 2. 将未到期的请求向前平移，覆盖掉已到期的请求
        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        // 3. 从数组末尾弹出多余的废弃元素 (pop 释放存储空间，可以退还部分 Gas)
        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        // 4. 执行真正的转账
        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_); // 自定义的底层以太坊安全转账
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(
                    msg.sender,
                    pendingWithdraw_
                );
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }



    event Claim(address indexed user, uint256 indexed poolId, uint256 MetaNodeReward);

    /**
     * @notice 提取 MetaNode 代币收益
     */
    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pools[_pid];
        User storage user_ = users[_pid][msg.sender];

        // 1. 强制结算最新收益
        updatePool(_pid);

        // 2. 计算应得总收益 (当前块的新收益 + 之前积攒的 pending 收益)
        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether) -
            user_.finishedMetaNode +
            user_.pendingMetaNode;

        // 3. 执行转账，并把暂存区清零
        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = 0;
            _safeMetaNodeTransfer(msg.sender, pendingMetaNode_); // 安全转账，防止精度导致合约余额不足
        }

        // 4. 重置已结算高水位线
        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            (1 ether);

        emit Claim(msg.sender, _pid, pendingMetaNode_);
    }
}