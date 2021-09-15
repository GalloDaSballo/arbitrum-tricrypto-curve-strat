from brownie import network, BadgerRegistry, Controller, interface, web3
from config import REGISTRY
from helpers.constants import AddressZero
from rich.console import Console
from tabulate import tabulate

console = Console()

DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000"

tableHead = ["Role", "MemberCount", "Address"]

def main():
    """
    Checks that the proxyAdmin of all conracts added to the BadgerRegistry match
    the proxyAdminTimelock address on the same registry. How to run:

    1. Add all keys to check paired to the key of the expected DEFAULT_ADMIN_ROLE to the 
       'keysWithAdmins' array.
    
    2. Add an array with all the expected roles belonging to each one of the keyed contracts
       added on the previous step to the 'roles' array. The index of the key must match the index
       of its roles array.

    3. Additionally, the script will check that the controller's governance and strategist match
       the Badger's production configuration addresses.

    4. Run the script and analyze the printed results.
    """

    console.print("You are using the", network.show_active(), "network")

    # Get production registry
    registry = BadgerRegistry.at(REGISTRY)

    # NOTE: Add keys to check paired to the key of their expected DEFAULT_ADMIN_ROLE:
    keysWithAdmins = [
        ["badgerTree", "governance"],
        ["BadgerRewardsManager", "governance"],
        ["rewardsLogger", "governance"],
        ["guardian", "governance"],
        ["keeper", "devGovernance"],
    ]

    # NOTE: Add all the roles related to the keys to check from the previous array. Indexes must match!
    roles = [
        ["DEFAULT_ADMIN_ROLE", "ROOT_PROPOSER_ROLE", "ROOT_VALIDATOR_ROLE", "PAUSER_ROLE", "UNPAUSER_ROLE"],
        ["DEFAULT_ADMIN_ROLE", "SWAPPER_ROLE", "DISTRIBUTOR_ROLE"],
        ["DEFAULT_ADMIN_ROLE", "MANAGER_ROLE"],
        ["DEFAULT_ADMIN_ROLE", "APPROVED_ACCOUNT_ROLE"],
        ["DEFAULT_ADMIN_ROLE", "EARNER_ROLE", "HARVESTER_ROLE", "TENDER_ROLE"],
    ]

    assert len(keysWithAdmins) == len(roles)

    check_roles(registry, keysWithAdmins, roles)
    check_controller_roles(registry)


def check_roles(registry, keysWithAdmins, roles):
    for key in keysWithAdmins:
        console.print("[blue]Checking roles for[/blue]", key[0])

        # Get contract address
        contract = registry.get(key[0])
        admin = registry.get(key[1])
        
        if contract == AddressZero:
            console.print("[red]Key not found on registry![/red]")
            continue

        tableData = []

        accessControl = interface.IAccessControl(contract)

        keyRoles = roles[keysWithAdmins.index(key)]
        hashes = get_roles_hashes(keyRoles)
        
        for role in keyRoles:
            roleHash = hashes[keyRoles.index(role)]
            roleMemberCount = accessControl.getRoleMemberCount(roleHash)
            if roleMemberCount == 0:
                tableData.append([role, "-", "No Addresses found for this role"])
            else:
                for memberNumber in range(roleMemberCount):
                    memberAddress = accessControl.getRoleMember(roleHash, memberNumber)
                    if role == "DEFAULT_ADMIN_ROLE":
                        if memberAddress == admin:
                            console.print("[green]DEFAULT_ADMIN_ROLE matches[/green]", key[1], admin)
                        else: 
                            console.print("[red]DEFAULT_ADMIN_ROLE doesn't match[/red]", key[1], admin)
                    tableData.append([role, memberNumber, memberAddress])

        print(tabulate(tableData, tableHead, tablefmt="grid"))

def check_controller_roles(registry):
    console.print("[blue]Checking roles for Controller...[/blue]")

    controllerAddress = registry.get("controller")
    governance = registry.get("governance")
    governanceTimelock = registry.get("governanceTimelock")

    assert controllerAddress != AddressZero
    assert governance != AddressZero
    assert governanceTimelock != AddressZero

    controller = Controller.at(controllerAddress)

    # Check governance
    if controller.governance() == governanceTimelock:
        console.print(
            "[green]controller.governance() matches governanceTimelock -[/green]", 
            governanceTimelock
        )
    else: 
        console.print(
            "[red]controller.governance() doesn't match governanceTimelock -[/red]", 
            controller.governance()
        )
    # Check strategist
    if controller.strategist() == governance:
        console.print(
            "[green]controller.strategist() matches governance -[/green]", 
            governance
        )
    else: 
        console.print(
            "[red]controller.strategist() doesn't match governance -[/red]", 
            controller.strategist()
        )

def get_roles_hashes(roles):
    hashes = []
    for role in roles:
        if role == "DEFAULT_ADMIN_ROLE":
            hashes.append(DEFAULT_ADMIN_ROLE)
        else:
            hashes.append(web3.keccak(text=role).hex())

    return hashes

