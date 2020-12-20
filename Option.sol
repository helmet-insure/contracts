// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "./Governable.sol";
import "./Proxy.sol";
import "./UniswapLibrary.sol";

contract Constants {
    bytes32 internal constant _LongOption_      = 'LongOption';
    bytes32 internal constant _ShortOption_     = 'ShortOption';
    bytes32 internal constant _feeRate_         = 'feeRate';
    bytes32 internal constant _feeRecipient_    = 'feeRecipient';
    bytes32 internal constant _uniswapRounter_  = 'uniswapRounter';
    bytes32 internal constant _mintOnlyBy_      = 'mintOnlyBy';
}

contract OptionFactory is Configurable, Constants {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    mapping(bytes32 => address) public productImplementations;
    mapping(address => mapping(address => mapping(address => mapping(uint => mapping(uint => address))))) public longs;
    mapping(address => mapping(address => mapping(address => mapping(uint => mapping(uint => address))))) public shorts;
    address[] public allLongs;
    address[] public allShorts;
    
    function length() public view returns (uint) {
        return allLongs.length;
    }

    function initialize(address _governor, address _implLongOption, address _implShortOption, address _feeRecipient, address _mintOnlyBy) public initializer {
        super.initialize(_governor);
        productImplementations[_LongOption_]    = _implLongOption;
        productImplementations[_ShortOption_]   = _implShortOption;
        config[_feeRate_]                       = 0.005 ether;               //0.002 ether;        // 0.2%
        config[_feeRecipient_]                  = uint(_feeRecipient);
        config[_uniswapRounter_]                = uint(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
        config[_mintOnlyBy_]                    = uint(_mintOnlyBy);
    }

    function upgradeProductImplementationsTo(address _implLongOption, address _implShortOption) external governance {
        productImplementations[_LongOption_] = _implLongOption;
        productImplementations[_ShortOption_] = _implShortOption;
    }
    
    function createOption(bool _private, address _collateral, address _underlying, uint _strikePrice, uint _expiry) public returns (address long, address short) {
        require(_collateral != _underlying, 'IDENTICAL_ADDRESSES');
        require(_collateral != address(0) && _underlying != address(0), 'ZERO_ADDRESS');
        require(_strikePrice != 0, 'ZERO_STRIKE_PRICE');
        require(_expiry > now, 'Cannot create an expired option');

        address creator = _private ? tx.origin : address(0);
        require(longs[creator][_collateral][_underlying][_strikePrice][_expiry] == address(0), 'SHORT_PROXY_EXISTS');     // single check is sufficient

        bytes32 salt = keccak256(abi.encodePacked(creator, _collateral, _underlying, _strikePrice, _expiry));

        bytes memory bytecode = type(LongProxy).creationCode;
        assembly {
            long := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        InitializableProductProxy(payable(long)).initialize(address(this), abi.encodeWithSignature('initialize(address,address,address,uint256,uint256)', creator, _collateral, _underlying, _strikePrice, _expiry));
        
        bytecode = type(ShortProxy).creationCode;
        assembly {
            short := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        InitializableProductProxy(payable(short)).initialize(address(this), abi.encodeWithSignature('initialize(address,address,address,uint256,uint256)', creator, _collateral, _underlying, _strikePrice, _expiry));

        longs [creator][_collateral][_underlying][_strikePrice][_expiry] = long;
        shorts[creator][_collateral][_underlying][_strikePrice][_expiry] = short;
        allLongs.push(long);
        allShorts.push(short);
        emit OptionCreated(creator, _collateral, _underlying, _strikePrice, _expiry, long, short, allLongs.length);
    }
    event OptionCreated(address indexed creator, address indexed _collateral, address indexed _underlying, uint _strikePrice, uint _expiry, address long, address short, uint count);
    
    function mint(bool _private, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume) public returns (address long, address short, uint vol) {
        require(config[_mintOnlyBy_] == 0 || address(config[_mintOnlyBy_]) == msg.sender, 'mint denied');
        address creator = _private ? tx.origin : address(0);
        long  = longs [creator][_collateral][_underlying][_strikePrice][_expiry];
        short = shorts[creator][_collateral][_underlying][_strikePrice][_expiry];
        if(short == address(0))                                                                      // single check is sufficient
            (long, short) = createOption(_private, _collateral, _underlying, _strikePrice, _expiry);
        
        IERC20(_collateral).safeTransferFrom(msg.sender, short, volume);
        ShortOption(short).mint_(msg.sender, volume);
        LongOption(long).mint_(msg.sender, volume);
        vol = volume;
        
        emit Mint(msg.sender, _private, _collateral, _underlying, _strikePrice, _expiry, long, short, vol);
    }
    event Mint(address indexed seller, bool _private, address indexed _collateral, address indexed _underlying, uint _strikePrice, uint _expiry, address long, address short, uint vol);
    
    function mint(address longOrShort, uint volume) external returns (address, address, uint) {
        LongOption long = LongOption(longOrShort);
        return mint(long.creator()!=address(0), long.collateral(), long.underlying(), long.strikePrice(), long.expiry(), volume);
    }

    function burn(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume) public returns (address long, address short, uint vol) {
        long  = longs [_creator][_collateral][_underlying][_strikePrice][_expiry];
        short = shorts[_creator][_collateral][_underlying][_strikePrice][_expiry];
        require(short != address(0), 'ZERO_ADDRESS');                                        // single check is sufficient

        LongOption(long).burn_(msg.sender, volume);
        ShortOption(short).burn_(msg.sender, volume);
        vol = volume;
        
        emit Burn(msg.sender, _creator, _collateral, _underlying, _strikePrice, _expiry, vol);
    }
    event Burn(address indexed seller, address _creator, address indexed _collateral, address indexed _underlying, uint _strikePrice, uint _expiry, uint vol);

    function burn(address longOrShort, uint volume) external returns (address, address, uint) {
        LongOption long = LongOption(longOrShort);
        return burn(long.creator(), long.collateral(), long.underlying(), long.strikePrice(), long.expiry(), volume);
    }

    function calcExerciseAmount(address _long, uint volume) public view returns (uint) {
        return calcExerciseAmount(volume, LongOption(_long).strikePrice());
    }
    function calcExerciseAmount(uint volume, uint _strikePrice) public pure returns (uint) {
        return volume.mul(_strikePrice).div(1 ether);
    }
    
    function _exercise(address buyer, address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume, address[] memory path) internal returns (uint vol, uint fee, uint amt) {
        require(now <= _expiry, 'Expired');
        
        address long  = longs[_creator][_collateral][_underlying][_strikePrice][_expiry];
        LongOption(long).burn_(buyer, volume);
        
        address short = shorts[_creator][_collateral][_underlying][_strikePrice][_expiry];
        amt = calcExerciseAmount(volume, _strikePrice);
        if(path.length == 0) {
            IERC20(_underlying).safeTransferFrom(buyer, short, amt);
            (vol, fee) = ShortOption(short).exercise_(buyer, volume);
        } else {
            (vol, fee) = ShortOption(short).exercise_(address(this), volume);
            IERC20(_collateral).safeApprove(address(config[_uniswapRounter_]), vol);
            uint[] memory amounts = IUniswapV2Router01(config[_uniswapRounter_]).swapTokensForExactTokens(amt, vol, path, short, now);
            vol = vol.sub(amounts[0]);
            IERC20(_collateral).safeTransfer(buyer, vol);
            amt = 0;
        }
        emit Exercise(buyer, _collateral, _underlying, _strikePrice, _expiry, volume, vol, fee, amt);
    }
    event Exercise(address indexed buyer, address indexed _collateral, address indexed _underlying, uint _strikePrice, uint _expiry, uint volume, uint vol, uint fee, uint amt);
    
    function exercise_(address buyer, address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume, address[] calldata path) external returns (uint vol, uint fee, uint amt) {
        address long  = longs[_creator][_collateral][_underlying][_strikePrice][_expiry];
        require(msg.sender == long, 'Only LongOption');
        
        return _exercise(buyer, _creator, _collateral, _underlying, _strikePrice, _expiry, volume, path);
    }
    
    function exercise(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume, address[] calldata path) external returns (uint vol, uint fee, uint amt) {
        return _exercise(msg.sender, _creator, _collateral, _underlying, _strikePrice, _expiry, volume, path);
    }
    
    function exercise(address _long, uint volume, address[] memory path) public returns (uint vol, uint fee, uint amt) {
        LongOption long = LongOption(_long);
        return _exercise(msg.sender, long.creator(), long.collateral(), long.underlying(), long.strikePrice(), long.expiry(), volume, path);
    }

    function exercise(address _long, uint volume) public returns (uint vol, uint fee, uint amt) {
        LongOption long = LongOption(_long);
        return _exercise(msg.sender, long.creator(), long.collateral(), long.underlying(), long.strikePrice(), long.expiry(), volume, new address[](0));
    }

    function exercise(address long, address[] calldata path) external returns (uint vol, uint fee, uint amt) {
        return exercise(long, LongOption(long).balanceOf(msg.sender), path);
    }

    function exercise(address long) external returns (uint vol, uint fee, uint amt) {
        return exercise(long, LongOption(long).balanceOf(msg.sender), new address[](0));
    }

    function settleable(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume) public view returns (uint vol, uint col, uint fee, uint und) {
        address short = shorts[_creator][_collateral][_underlying][_strikePrice][_expiry];
        return ShortOption(short).settleable(volume);
    }
    function settleable(address short, uint volume) public view returns (uint vol, uint col, uint fee, uint und) {
        return ShortOption(short).settleable(volume);
    }
    function settleable(address seller, address short) public view returns (uint vol, uint col, uint fee, uint und) {
        return ShortOption(short).settleable(seller);
    }
    
    function settle(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint volume) external returns (uint vol, uint col, uint fee, uint und) {
        address short = shorts[_creator][_collateral][_underlying][_strikePrice][_expiry];
        return settle(short, volume);
    }
    function settle(address short, uint volume) public returns (uint vol, uint col, uint fee, uint und) {
        return ShortOption(short).settle_(msg.sender, volume);
    }
    function settle(address short) external returns (uint vol, uint col, uint fee, uint und) {
        return settle(short, ShortOption(short).balanceOf(msg.sender));
    }
    
    function emitSettle(address seller, address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry, uint vol, uint col, uint fee, uint und) external {
        address short  = shorts[_creator][_collateral][_underlying][_strikePrice][_expiry];
        require(msg.sender == short, 'Only ShortOption');
        emit Settle(seller, _creator, _collateral, _underlying, _strikePrice, _expiry, vol, col, fee, und);
    }
    event Settle(address indexed seller, address _creator, address indexed _collateral, address indexed _underlying, uint _strikePrice, uint _expiry, uint vol, uint col, uint fee, uint und);
}

contract LongProxy is InitializableProductProxy, Constants {
    function productName() override public pure returns (bytes32) {
        return _LongOption_;
    }
}

contract ShortProxy is InitializableProductProxy, Constants {
    function productName() override public pure returns (bytes32) {
        return _ShortOption_;
    }
}


contract LongOption is ERC20UpgradeSafe {
    using SafeMath for uint;
    
    address public factory;
    address public creator;
    address public collateral;
    address public underlying;
    uint public strikePrice;
    uint public expiry;

    function initialize(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry) external initializer {
        (string memory name, string memory symbol) = spellNameAndSymbol(_collateral, _underlying, _strikePrice, _expiry);
        __ERC20_init(name, symbol);
        _setupDecimals(ERC20UpgradeSafe(_collateral).decimals());

        factory = msg.sender;
        creator = _creator;
        collateral = _collateral;
        underlying = _underlying;
        strikePrice = _strikePrice;
        expiry = _expiry;
    }
    
    function spellNameAndSymbol(address _collateral, address _underlying, uint _strikePrice, uint _expiry) public view returns (string memory name, string memory symbol) {
        //return ('Helmet.Insure ETH long put option strike 500 USDC or USDC long call option strike 0.002 ETH expiry 2020/10/10', 'USDC(0.002ETH)201010');
        return('Helmet.Insure Long Option Token', 'Long');
    }

    modifier onlyFactory {
        require(msg.sender == factory, 'Only Factory');
        _;
    }
    
    function mint_(address _to, uint volume) external onlyFactory {
        _mint(_to, volume);
    }
    
    function burn_(address _from, uint volume) external onlyFactory {
        _burn(_from, volume);
    }
    
    function burn(uint volume) external {
        _burn(msg.sender, volume);
    }
    function burn() external {
        _burn(msg.sender, balanceOf(msg.sender));
    }
    
    function exercise(uint volume, address[] memory path) public returns (uint vol, uint fee, uint amt) {
        return OptionFactory(factory).exercise_(msg.sender, creator, collateral, underlying, strikePrice, expiry, volume, path);
    }

    function exercise(uint volume) public returns (uint vol, uint fee, uint amt) {
        return exercise(volume, new address[](0));
    }

    function exercise(address[] calldata path) external returns (uint vol, uint fee, uint amt) {
        return exercise(balanceOf(msg.sender), path);
    }

    function exercise() external returns (uint vol, uint fee, uint amt) {
        return exercise(balanceOf(msg.sender), new address[](0));
    }
}

contract ShortOption is ERC20UpgradeSafe, Constants {
    using SafeERC20 for IERC20;
    using SafeMath for uint;
    
    address public factory;
    address public creator;
    address public collateral;
    address public underlying;
    uint public strikePrice;
    uint public expiry;

    function initialize(address _creator, address _collateral, address _underlying, uint _strikePrice, uint _expiry) external initializer {
        (string memory name, string memory symbol) = spellNameAndSymbol(_collateral, _underlying, _strikePrice, _expiry);
        __ERC20_init(name, symbol);
        _setupDecimals(ERC20UpgradeSafe(_collateral).decimals());

        factory = msg.sender;
        creator = _creator;
        collateral = _collateral;
        underlying = _underlying;
        strikePrice = _strikePrice;
        expiry = _expiry;
    }

    function spellNameAndSymbol(address _collateral, address _underlying, uint _strikePrice, uint _expiry) public view returns (string memory name, string memory symbol) {
        //return ('Helmet.Insure ETH short put option strike 500 USDC or USDC short call option strike 0.002 ETH expiry 2020/10/10', 'USDC(0.002ETH)201010s');
        return('Helmet.Insure Short Option Token', 'Short');
    }

    modifier onlyFactory {
        require(msg.sender == factory, 'Only Factory');
        _;
    }
    
    function mint_(address _to, uint volume) external onlyFactory {
        _mint(_to, volume);
    }
    
    function burn_(address _from, uint volume) external onlyFactory {
        _burn(_from, volume);
        IERC20(collateral).safeTransfer(_from, volume);
    }
    
    function calcFee(uint volume) public view returns (address recipient, uint fee) {
        uint feeRate = OptionFactory(factory).getConfig(_feeRate_);
        recipient = address(OptionFactory(factory).getConfig(_feeRecipient_));
        
        if(feeRate != 0 && recipient != address(0))
            fee = volume.mul(feeRate).div(1 ether);
        else
            fee = 0;
    }
    
    function _payFee(uint volume) internal returns (uint) {
        (address recipient, uint fee) = calcFee(volume);
        if(recipient != address(0) && fee > 0)
            IERC20(collateral).safeTransfer(recipient, fee);
        return fee;
    }
    
    function exercise_(address buyer, uint volume) external onlyFactory returns (uint vol, uint fee) {
        fee = _payFee(volume);
        vol = volume.sub(fee);
        IERC20(collateral).safeTransfer(buyer, vol);
    }
    
    function settle_(address seller, uint volume) external onlyFactory returns (uint vol, uint col, uint fee, uint und) {
        return _settle(seller, volume);
    }
    
    function settleable(address seller) public view returns (uint vol, uint col, uint fee, uint und) {
        return settleable(balanceOf(seller));
    }
    
    function settleable(uint volume) public view returns (uint vol, uint col, uint fee, uint und) {
        uint colla = IERC20(collateral).balanceOf(address(this));
        uint under = IERC20(underlying).balanceOf(address(this));
        if(now <= expiry) {
            address long  = OptionFactory(factory).longs(creator, collateral, underlying, strikePrice, expiry);
            uint waived = colla.sub(IERC20(long).totalSupply());
            uint exercised = totalSupply().sub(colla);
            uint we = waived.add(exercised);
            if(we == 0)
                return (0, 0, 0, 0);
            vol = volume <= we ? volume : we;
            col = waived.mul(vol).div(we);
            und = under.mul(vol).div(we);
        } else {
            vol = volume <= totalSupply() ? volume : totalSupply();
            col = colla.mul(vol).div(totalSupply());
            und = under.mul(vol).div(totalSupply());
        }
        (, fee) = calcFee(col);
        col = col.sub(fee);
    }
    
    function _settle(address seller, uint volume) internal returns (uint vol, uint col, uint fee, uint und) {
        (vol, col, fee, und) = settleable(volume);
        _burn(seller, vol);
        _payFee(col.add(fee));
        IERC20(collateral).safeTransfer(seller, col);
        IERC20(underlying).safeTransfer(seller, und);
        OptionFactory(factory).emitSettle(seller, creator, collateral, underlying, strikePrice, expiry, vol, col, fee, und);
    }
    
    function settle(uint volume) external returns (uint vol, uint col, uint fee, uint und) {
        return _settle(msg.sender, volume);
    }
    
    function settle() external returns (uint vol, uint col, uint fee, uint und) {
        return _settle(msg.sender, balanceOf(msg.sender));
    }
}
