// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektSwapRouter} from "../src/RektSwapRouter.sol";

contract DeploymentTest is HookFixture {
    function test_realCreate2DeploymentAtPermissionBitsWithEmptyExternalAddresses() public {
        // Explicitly prove launch simulation needs no manager/token/factory code in the constructor.
        IPoolManager emptyManager = IPoolManager(makeAddr("empty-manager"));
        address emptyFactory = makeAddr("empty-factory");
        address emptyPair = makeAddr("empty-pair");
        address emptyToken = makeAddr("empty-token");
        bytes memory creation = abi.encodePacked(
            type(RektJackpotHook).creationCode, abi.encode(emptyManager, owner, emptyFactory, emptyPair, emptyToken)
        );
        bytes32 hash = keccak256(creation);
        address deployed;
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            assembly ("memory-safe") {
                deployed := create2(0, add(creation, 32), mload(creation), salt)
            }
            assertEq(deployed, predicted);
            break;
        }
        assertTrue(deployed != address(0), "no suitable salt");
        RektJackpotHook fresh = RektJackpotHook(deployed);
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.poolManager()), address(emptyManager));
        assertEq(fresh.factory(), emptyFactory);
        assertEq(fresh.launchToken(), emptyToken);
        Hooks.validateHookPermissions(IHooks(deployed), fresh.getHookPermissions());
    }

    function test_runtimeSizeAndNoEscapeOpcodes() public view {
        _checkRuntime(address(token));
        _checkRuntime(address(hook));
        _checkRuntime(address(router));
    }

    function test_wrongPermissionAddressRevertsInConstructor() public {
        vm.expectRevert();
        new RektJackpotHook(manager, owner, address(factory), address(quote), address(token));
    }

    function test_initRejectsWrongPairFeeSpacingAndHookBeforeBinding() public {
        address at = address(uint160(0x400000) | FLAGS);
        deployCodeTo(
            "RektJackpotHook.sol:RektJackpotHook",
            abi.encode(manager, owner, address(factory), address(quote), address(token)),
            at
        );
        RektJackpotHook fresh = RektJackpotHook(at);
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(at);
        vm.startPrank(address(manager));
        candidate.fee = 0;
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        fresh.beforeInitialize(address(factory), candidate, PRICE);
        candidate.fee = 0x800000;
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        fresh.beforeInitialize(address(factory), candidate, PRICE);
        candidate.fee = 12500;
        candidate.tickSpacing = 10;
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        fresh.beforeInitialize(address(factory), candidate, PRICE);
        candidate.tickSpacing = 60;
        candidate.currency0 = Currency.wrap(alice);
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        fresh.beforeInitialize(address(factory), candidate, PRICE);
        candidate.currency0 = key.currency0;
        candidate.hooks = key.hooks;
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        fresh.beforeInitialize(address(factory), candidate, PRICE);
        vm.stopPrank();
        candidate.hooks = IHooks(at);
        factory.initialize(candidate, PRICE);
        assertTrue(fresh.initialized());
    }

    function test_wrongRouterManagerOrHookRejected() public {
        _deploy(true, true, false);
        RektSwapRouter wrong = new RektSwapRouter(IPoolManager(makeAddr("other-manager")), hook);
        vm.prank(owner);
        vm.expectRevert(RektJackpotHook.InvalidRouter.selector);
        hook.configureRouter(address(wrong));
        wrong = new RektSwapRouter(manager, RektJackpotHook(makeAddr("other-hook")));
        vm.prank(owner);
        vm.expectRevert(RektJackpotHook.InvalidRouter.selector);
        hook.configureRouter(address(wrong));
    }

    function test_twoStepOwnershipDoesNotRedirectCreatorFees() public {
        vm.prank(owner);
        hook.transferOwnership(bob);
        assertEq(hook.owner(), owner);
        vm.prank(alice);
        vm.expectRevert();
        hook.acceptOwnership();
        vm.prank(bob);
        hook.acceptOwnership();
        assertEq(hook.owner(), bob);
        vm.prank(bob);
        vm.expectRevert(RektJackpotHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        _buy(alice, 100 ether);
        assertEq(hook.creatorFeeRecipient(), owner);
        assertEq(quote.balanceOf(owner), 0.5 ether);
        _assertConservation();
    }

    function _checkRuntime(address at) private view {
        bytes memory code = at.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "escape opcode");
        }
    }
}
