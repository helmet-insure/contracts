// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "./Helmet.sol";
import "./UniswapLibrary.sol";

contract RecruitLP is Configurable {
    using SafeMath for uint;
    using TransferHelper for address;
    using TransferHelper for address payable;

	bytes32 internal constant _token_					        = "token";
    bytes32 internal constant _piece_                           = 'piece';
    //bytes32 internal constant _maxN1_                           = 'maxN1';
    bytes32 internal constant _maxValue_                        = 'maxValue';
    bytes32 internal constant _ratio_                           = 'ratio';
    bytes32 internal constant _ratioSwap_                       = 'ratioSwap';
	//bytes32 internal constant _whitelist_				    	= 'whitelist';
	bytes32 internal constant _total_				    	    = 'total';
	bytes32 internal constant _addedValue_                      = 'addedValue';
	bytes32 internal constant _lptAmount_                       = 'lptAmount';
	bytes32 internal constant _close1N_                         = 'close1N';

	uint256 internal constant _status_initialize_               = 0;
	uint256 internal constant _status_recruit1_                 = 1;
	uint256 internal constant _status_recruit2_                 = 2;
	uint256 internal constant _status_recruit3_                 = 3;
	uint256 internal constant _status_refund_                   = 4;

	bytes32 internal constant _status_					        = 'status';
	
	address public constant uniswapRounter                      = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
	
	address payable[] public lp1s;
	uint[] public value1s;
	uint internal close1index;

    //constructor(address owner, address token) public {
    //    initialize(owner, token);
    //}
    
    function initialize(address governor_, address token) public initializer {
        super.initialize(governor_);
        
        config[_token_]             = uint(token);
        //config[_maxN1_]             = 30;
        config[_maxValue_]          = 3 ether;      //30000 ether;  //todo: test
        //config[_piece_]             = 100 ether;
        //config[_ratio_]             = 2000 ether;
        config[_piece_]             = 0.01 ether;   //100 ether;    //todo: test
        config[_ratio_]             = 3000000 ether; //300 ether;   //todo: test
        config[_ratioSwap_]         = 0.1 ether;
        config[_close1N_]           = 100;
    }
    
    //function addWhitelist(address addr) public governance {
    //    _setConfig(_whitelist_, addr, 1);
    //}
    //
    //function addWhitelist(address[] memory addrs) public {
    //    for(uint i=0; i<addrs.length; i++)
    //        addWhitelist(addrs[i]);
    //}
    
    /// @notice This method can be used by the owner to extract mistakenly
    ///  sent tokens to this contract.
    /// @param _token The address of the token contract that you want to recover
    function rescueTokens(address _token, address _dst) public governance {
        IERC20 token = IERC20(_token);
        uint balance = token.balanceOf(address(this));
        token.transfer(_dst, balance);
    }
    
    function withdrawToken(address _dst) public governance {
        rescueTokens(address(config[_token_]), _dst);
    }

    function withdrawToken() public governance {
        rescueTokens(address(config[_token_]), msg.sender);
    }
    
    function withdrawETH(address payable _dst) public governance {
        _dst.transfer(address(this).balance);
    }
    
    function withdrawETH() public governance {
        msg.sender.transfer(address(this).balance);
    }

    function refund1() external governance {
        require(config[_status_] == _status_recruit1_, 'Not recruit1 status');
        for(uint i=0; i<lp1s.length; i++) {
            lp1s[i].transfer(value1s[i]);
        }
        config[_status_] = _status_refund_;
    }
    
    function close1() external governance {
        require(config[_status_] == _status_recruit1_, 'Not recruit1 status');

        uint value = config[_total_].sub(config[_addedValue_]).div(2);
        uint amount = value.mul(config[_ratio_]).div(1 ether);
        
        if(value > 0) {
            amount = _addLiquidity(value, amount, address(this));
            config[_lptAmount_] = config[_lptAmount_].add(amount);
            config[_addedValue_] = config[_total_];
        }
        amount = config[_lptAmount_];
        address LPT = getPair();
        uint i = 0;
        for(i=close1index; i<close1index+config[_close1N_] && i<lp1s.length; i++) {
            uint amt = amount.mul(value1s[i]).div(config[_total_]);
            LPT.safeTransfer(lp1s[i], amt);
            emit Recruit(lp1s[i], value1s[i], amt);
        }
        close1index = i;
        if(i < lp1s.length)
            return;

        //if(lp1s.length < config[_maxN1_])
        if(config[_total_] < config[_maxValue_])
            _setStatus(_status_recruit2_);
        else
            _setStatus(_status_recruit3_);
    }
    
    function setStatus(uint status) public governance {
        _setStatus(status);
    }
    function _setStatus(uint status) internal {
        _setConfig(_status_, status);
        emit Status(status);
    }
    event Status(uint status);
    
    function _addLiquidity(uint value, uint amount, address to) internal returns (uint amtLP) {
        address(config[_token_]).safeApprove(address(uniswapRounter), amount);
        (, , amtLP) = IUniswapV2Router01(uniswapRounter).addLiquidityETH{value: value}(address(config[_token_]), amount, 0, 0, to, now);
    }
    
    function _swapExactETHForTokens(uint value) internal returns (uint amount) {
        uint[] memory amounts= IUniswapV2Router01(uniswapRounter).swapExactETHForTokens{value: value}(0, getPath(), address(this), now);
        return amounts[1];
    }
    
    function getPath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = IUniswapV2Router01(uniswapRounter).WETH();
        path[1] = address(config[_token_]);
    }

    function getPair() public view returns (address) {
        return UniswapV2Library.pairFor(address(config[_token_]), IUniswapV2Router01(uniswapRounter).WETH());
    }
    
    function getProgess() public view returns (uint) {
        //uint max = config[_piece_].mul(config[_maxN1_]);
        uint max = config[_maxValue_];
        if(max <= config[_total_])
            return 1 ether;
        return config[_total_].mul(1 ether).div(max);
    }
    
    //function recruit1(address payable[] memory tos) external payable {
    //    require(config[_status_] == _status_recruit1_, 'Not recruit1 status');
    //
    //    uint valueN = config[_piece_].mul(tos.length);
    //    require(msg.value >= valueN, 'value is too little');
    //    
    //    for(uint i=0; i<tos.length; i++) 
    //        _recruit1(config[_piece_], tos[i]);
    //        
    //    if(msg.value > valueN) {
    //        msg.sender.transfer(msg.value.sub(valueN));
    //    }
    //}
    
    function _recruit1(uint value, address payable to) internal returns (uint) {
        require(config[_status_] == _status_recruit1_, 'Not recruit1 status');
        //require(getConfig(_whitelist_, to) >= 1, 'Not in the whitelist');
        //require(getConfig(_whitelist_, to) <= 1, 'enlist already');
        //require(value >= config[_piece_], 'value is too little');
        //require(lp1s.length < config[_maxN1_], 'Quota is full');
        require(config[_total_] < config[_maxValue_], 'Quota is full');

        
        lp1s.push(to);
        if(value > config[_piece_]) {
            to.transfer(value.sub(config[_piece_]));
            value = config[_piece_];
        }
        if(value.add(config[_total_]) > config[_maxValue_]) {
            to.transfer(value.add(config[_total_]).sub(config[_maxValue_]));
            value = config[_maxValue_].sub(config[_total_]);
        }
        value1s.push(value);
        //_setConfig(_whitelist_, to, 2);
        _setConfig(_total_, config[_total_].add(value));

        return 0;
    }
    
    function _recruit2(uint value, address payable to) internal returns (uint amount) {
        require(config[_status_] == _status_recruit2_, 'Not recruit2 status');

        uint v = value;
        if(v > config[_piece_])
            v = config[_piece_];
            
        amount = _swapExactETHForTokens(v.mul(config[_ratioSwap_]).div(1 ether));
        amount = _addLiquidity(v.div(2), IERC20(config[_token_]).balanceOf(address(this)), to);
        _setConfig(_total_, config[_total_].add(v));
        emit Recruit(to, v, amount);

        if(value > config[_piece_])
            to.transfer(value.sub(config[_piece_]));
            
        if(getProgess() >= 1 ether)
            _setStatus(_status_recruit3_);
    }
    
    function _recruit3(uint value, address payable to) internal returns (uint amount) {
        require(config[_status_] == _status_recruit3_, 'Not recruit3 status');

        uint v = value;
        if(v > config[_piece_])
            v = config[_piece_];
            
        amount = _swapExactETHForTokens(v.div(2));
        amount = _addLiquidity(v.div(2), IERC20(config[_token_]).balanceOf(address(this)), to);
        _setConfig(_total_, config[_total_].add(v));
        emit Recruit(to, v, amount);

        if(value > config[_piece_])
            to.transfer(value.sub(config[_piece_]));
     }
    
    function recruit() public payable returns (uint) {
        if(config[_status_] == _status_recruit1_) {
            return _recruit1(msg.value, msg.sender);
        } else if(config[_status_] == _status_recruit2_) {
            return _recruit2(msg.value, msg.sender);
        } else if(config[_status_] == _status_recruit3_) {
            return _recruit3(msg.value, msg.sender);
        } else 
            revert('Not recruit status');
    }
    event Recruit(address lp, uint value, uint amount);
    
    receive() external payable {
        recruit();
    }
}

