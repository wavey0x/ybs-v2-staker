import brownie
from brownie import Contract, accounts, ZERO_ADDRESS
import pytest

WEEK = 60*60*24*7

def test_swapper(swapper_v4, vault, deposit_rewards, chain, gov, old_strategy, management, crvusd_dummy_vault):
    swapper = swapper_v4
    strategy = old_strategy
    old_swapper = Contract(strategy.swapper())
    price = 1 / (swapper.priceOracle()/1e18) # yCRV price as crvUSD
    assert price > 0.10 and price < 1.0
    tx = strategy.harvest({'from': gov})
    strategy.upgradeSwapper(swapper, {'from': gov})
    assert swapper.management() == management
    whale = accounts.at('0x71E47a4429d35827e0312AA13162197C23287546', force=True)
    ycrv = Contract(vault.token())
    chain.sleep(3*WEEK)
    chain.mine()

    v = swapper.vault()
    swapper.setVault(crvusd_dummy_vault, {'from': gov})
    swapper.setVault(v, {'from': gov})

    amounts = [10e18, 1_000e18, 100_000e18, 0]

    status = swapper.otcEnabled()

    for i in range(len(amounts)):
        ycrv.transfer(swapper, amounts[i], {'from': whale})
    
        deposit_rewards()
        
        chain.sleep(WEEK)
        chain.mine()

        if i % 3 == 0:
            swapper.enableOtc(not status, {'from': management})
            assert swapper.otcEnabled() != status
        
        status = swapper.otcEnabled()

        tx = strategy.harvest({'from': gov})

        if status:
            assert 'OTC' in tx.events
            event = tx.events['OTC']
            print('Sell amount',event['sellTokenAmount']/1e18)
            print('Buy amount',event['buyTokenAmount']/1e18)
            bal = Contract(swapper.tokenOut()).balanceOf(swapper) / 1e18
            print(f'Remaining OTC balance {bal}\n')
        else:
            assert 'OTC' not in tx.events

def test_swapper_settings(swapper_v4, management, user):
    swapper = swapper_v4
    swapper.setAllowedSwapper(user, True, {'from': management})
    assert swapper.allowedSwapper(user)
    swapper.setAllowedSwapper(user, False, {'from': management})
    assert not swapper.allowedSwapper(user)

    with brownie.reverts():
        swapper.setAllowedSwapper(ZERO_ADDRESS, True, {'from': user})
