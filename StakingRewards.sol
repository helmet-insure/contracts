// SPDX-License-Identifier: MIT

//pragma solidity ^0.5.16;
pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "./Governable.sol";

// Inheritancea
interface IStakingRewards {
    // Views
    function lastTimeRewardApplicable() external view returns (uint256);

    function rewardPerToken() external view returns (uint256);

    function rewards(address account) external view returns (uint256);

    function earned(address account) external view returns (uint256);

    function getRewardForDuration() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    // Mutative

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;
}

abstract contract RewardsDistributionRecipient {
    address public rewardsDistribution;

    function notifyRewardAmount(uint256 reward) virtual external;

    modifier onlyRewardsDistribution() {
        require(msg.sender == rewardsDistribution, "Caller is not RewardsDistribution contract");
        _;
    }
}

contract StakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuardUpgradeSafe {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;                  // obsoleted
    uint256 public rewardsDuration = 60 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) override public rewards;

    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    /* ========== CONSTRUCTOR ========== */

    //constructor(
    function initialize(
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public virtual initializer {
        super.__ReentrancyGuard_init();
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution;
    }

    /* ========== VIEWS ========== */

    function totalSupply() override external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() override public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() virtual override public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) override public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() virtual override external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stakeWithPermit(uint256 amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        // permit
        IUniswapV2ERC20(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function stake(uint256 amount) virtual override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) virtual override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() virtual override public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() virtual override public {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) override external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) virtual {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
}

interface IUniswapV2ERC20 {
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

contract StakingPool is Configurable, StakingRewards {
    using Address for address payable;
    
    bytes32 internal constant _ecoAddr_         = 'ecoAddr';
    bytes32 internal constant _ecoRatio_        = 'ecoRatio';
	bytes32 internal constant _allowContract_   = 'allowContract';
	bytes32 internal constant _allowlist_       = 'allowlist';
	bytes32 internal constant _blocklist_       = 'blocklist';


	uint public lep;            // 1: linear, 2: exponential, 3: power
	uint public period;
	uint public begin;

    function initialize(address _governor, 
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public virtual initializer {
	    super.initialize(_governor);
        super.initialize(_rewardsDistribution, _rewardsToken, _stakingToken);
    }

    function notifyRewardBegin(uint _lep, uint _period, uint _span, uint _begin) virtual public governance updateReward(address(0)) {
        lep             = _lep;         // 1: linear, 2: exponential, 3: power
        period          = _period;
        rewardsDuration = _span;
        begin           = _begin;
        periodFinish    = _begin.add(_span);
    }

    function rewardDelta() public view returns (uint amt) {
        if(begin == 0 || begin >= now || lastUpdateTime >= now)
            return 0;
            
        amt = rewardsToken.allowance(rewardsDistribution, address(this)).sub(rewards[address(0)]);
        
        // calc rewardDelta in period
        if(lep == 3) {                                                              // power
            uint y = period.mul(1 ether).div(lastUpdateTime.add(rewardsDuration).sub(begin));
            uint amt1 = amt.mul(1 ether).div(y);
            uint amt2 = amt1.mul(period).div(now.add(rewardsDuration).sub(begin));
            amt = amt.sub(amt2);
        } else if(lep == 2) {                                                       // exponential
            if(now.sub(lastUpdateTime) < rewardsDuration)
                amt = amt.mul(now.sub(lastUpdateTime)).div(rewardsDuration);
        }else if(now < periodFinish)                                                // linear
            amt = amt.mul(now.sub(lastUpdateTime)).div(periodFinish.sub(lastUpdateTime));
        else if(lastUpdateTime >= periodFinish)
            amt = 0;
    }
    
    function rewardPerToken() override public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                rewardDelta().mul(1e18).div(_totalSupply)
            );
    }

    modifier updateReward(address account) override {
        rewardPerTokenStored = rewardPerToken();
        rewards[address(0)] = rewards[address(0)].add(rewardDelta());
        lastUpdateTime = now;
        if (account != address(0)) {
            uint amt = rewards[account];
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;

            amt = rewards[account].sub(amt);
            address addr = address(config[_ecoAddr_]);
            uint ratio = config[_ecoRatio_];
            if(addr != address(0) && ratio != 0) {
                uint a = amt.mul(ratio).div(1 ether);
                rewards[addr] = rewards[addr].add(a);
                rewards[address(0)] = rewards[address(0)].add(a);
            }
        }
        _;
    }

    function getReward() override public nonReentrant updateReward(msg.sender) {
        require(getConfig(_blocklist_, msg.sender) == 0, 'In blocklist');
        bool isContract = msg.sender.isContract();
        require(!isContract || config[_allowContract_] != 0 || getConfig(_allowlist_, msg.sender) != 0, 'No allowContract');

        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewards[address(0)] = rewards[address(0)].sub(reward);
            rewardsToken.safeTransferFrom(rewardsDistribution, msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function getRewardForDuration() override external view returns (uint256) {
        return rewardsToken.allowance(rewardsDistribution, address(this)).sub(rewards[address(0)]);
    }
    
}

contract DoublePool is StakingPool {
    IStakingRewards public stakingPool2;
    IERC20 public rewardsToken2;
    //uint256 public lastUpdateTime2;                                 // obsoleted
    //uint256 public rewardPerTokenStored2;                           // obsoleted
    mapping(address => uint256) public userRewardPerTokenPaid2;
    mapping(address => uint256) public rewards2;

    function initialize(address, address, address, address) override public {
        revert();
    }
    
    function initialize(address _governor, address _rewardsDistribution, address _rewardsToken, address _stakingToken, address _stakingPool2, address _rewardsToken2) public initializer {
	    super.initialize(_governor, _rewardsDistribution, _rewardsToken, _stakingToken);
	    
	    stakingPool2 = IStakingRewards(_stakingPool2);
	    rewardsToken2 = IERC20(_rewardsToken2);
	}
    
    function notifyRewardBegin(uint _lep, uint _period, uint _span, uint _begin) virtual override public governance updateReward2(address(0)) {
        super.notifyRewardBegin(_lep, _period, _span, _begin);
    }
    
    function stake(uint amount) virtual override public updateReward2(msg.sender) {
        super.stake(amount);
        stakingToken.safeApprove(address(stakingPool2), amount);
        stakingPool2.stake(amount);
    }

    function withdraw(uint amount) virtual override public updateReward2(msg.sender) {
        stakingPool2.withdraw(amount);
        super.withdraw(amount);
    }
    
    function getReward2() virtual public nonReentrant updateReward2(msg.sender) {
        uint256 reward2 = rewards2[msg.sender];
        if (reward2 > 0) {
            rewards2[msg.sender] = 0;
            stakingPool2.getReward();
            rewardsToken2.safeTransfer(msg.sender, reward2);
            emit RewardPaid2(msg.sender, reward2);
        }
    }
    event RewardPaid2(address indexed user, uint256 reward2);

    function getDoubleReward() virtual public {
        getReward();
        getReward2();
    }
    
    function exit() override public {
        super.exit();
        getReward2();
    }
    
    function rewardPerToken2() virtual public view returns (uint256) {
        return stakingPool2.rewardPerToken();
    }

    function earned2(address account) virtual public view returns (uint256) {
        return _balances[account].mul(rewardPerToken2().sub(userRewardPerTokenPaid2[account])).div(1e18).add(rewards2[account]);
    }

    modifier updateReward2(address account) virtual {
        if (account != address(0)) {
            rewards2[account] = earned2(account);
            userRewardPerTokenPaid2[account] = rewardPerToken2();
        }
        _;
    }

}
