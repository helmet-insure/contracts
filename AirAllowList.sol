/**
 *Submitted for verification at BscScan.com on 2021-01-14
*/

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


contract Governable {
    address public governor;
    event GovernorshipTransferred(address indexed previousGovernor, address indexed newGovernor);

    /**
     * @dev Contract initializer.
     * called once by the factory at time of deployment
     */
    constructor()  public {
        governor = msg.sender;
        emit GovernorshipTransferred(address(0), governor);
    }

    modifier governance() {
        require(msg.sender == governor);
        _;
    }

    /**
     * @dev Allows the current governor to relinquish control of the contract.
     * @notice Renouncing to governorship will leave the contract without an governor.
     * It will not be possible to call the functions with the `governance`
     * modifier anymore.
     */
    function renounceGovernorship() public governance {
        emit GovernorshipTransferred(governor, address(0));
        governor = address(0);
    }

    /**
     * @dev Allows the current governor to transfer control of the contract to a newGovernor.
     * @param newGovernor The address to transfer governorship to.
     */
    function transferGovernorship(address newGovernor) public governance {
        _transferGovernorship(newGovernor);
    }

    /**
     * @dev Transfers control of the contract to a newGovernor.
     * @param newGovernor The address to transfer governorship to.
     */
    function _transferGovernorship(address newGovernor) internal {
        require(newGovernor != address(0));
        emit GovernorshipTransferred(governor, newGovernor);
        governor = newGovernor;
    }
}


contract AirAllowList is Governable{
    
    constructor() public{
        
    }
    
    mapping(address => uint) public allowList;
    mapping(address => bool) public withdrawList;
    address public tokenAddr;
    
    
    function setAirToken(address addr) external governance{
        tokenAddr = addr;
    }

    function addAllowList(address payable[] calldata dsts, uint value) external governance {
        for(uint i=0; i<dsts.length; i++)
            allowList[dsts[i]] = value;
    }
    
    
    
    function addAllowList(address payable[] calldata dsts, uint[] calldata values) external  governance {
        for(uint i=0; i<dsts.length; i++)
            allowList[dsts[i]] = values[i];
    }
    

    function withdraw() external payable {
        require(!withdrawList[msg.sender],"already withdraw!");
        if (tokenAddr == address(0x0))
            msg.sender.transfer(allowList[msg.sender]);
        else
            IERC20(tokenAddr).transfer(msg.sender, allowList[msg.sender]);
        withdrawList[msg.sender] = true;
        emit Withdraw(msg.sender,allowList[msg.sender]);
        
    }
    event Withdraw(address indexed to, uint256 value);

    function withdrawAll() external payable governance {
        if (tokenAddr != address(0x0)){
            uint amount = IERC20(tokenAddr).balanceOf(address(this));
            IERC20(tokenAddr).transfer(msg.sender, amount);
            emit Withdraw(msg.sender,amount);
        }
        msg.sender.transfer(address(this).balance);
        
    }

}