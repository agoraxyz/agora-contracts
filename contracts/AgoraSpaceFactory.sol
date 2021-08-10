// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./AgoraSpace.sol";
import "./token/AgoraToken.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title A contract that deploys Agora Space contracts for any community
contract AgoraSpaceFactory {
    /// @notice Token => deployed Space
    mapping(address => address) public spaces;

    event SpaceCreated(address token, address space, address agoraToken);

    /// @notice Deploys a new Agora Space contract with it's token and registers it in the spaces mapping
    /// @param _token The address of the community's token (that will be deposited to Space)
    function createSpace(address _token) external {
        require(_token != address(0));
        require(spaces[_token] == address(0), "Space aleady exists");
        string memory tokenSymbol = IERC20Metadata(_token).symbol();
        uint8 tokenDecimals = IERC20Metadata(_token).decimals();
        AgoraToken agoraToken = new AgoraToken(
            string(abi.encodePacked("Agora.space ", tokenSymbol, " Token")),
            "AGT",
            tokenDecimals
        );
        AgoraSpace agoraSpace = new AgoraSpace(_token, address(agoraToken));
        spaces[_token] = address(agoraSpace);
        agoraToken.transferOwnership(address(agoraSpace));
        agoraSpace.transferOwnership(address(msg.sender));
        emit SpaceCreated(_token, address(agoraSpace), address(agoraToken));
    }
}
