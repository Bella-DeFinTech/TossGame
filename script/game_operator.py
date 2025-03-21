from eth_account import Account
from web3 import Web3
import json
import time
from dotenv import load_dotenv
import os
from hexbytes import HexBytes
from eth_abi import encode


class TossGameOperator:
    def __init__(self, rpc_url, operator_key, game_address, token_address):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.operator = Account.from_key(operator_key)

        # Load contract ABIs
        with open("out/TossGame.sol/TossGame.json") as f:
            game_abi = json.load(f)["abi"]
        with open("out/MockERC20.sol/MockERC20.json") as f:
            token_abi = json.load(f)["abi"]

        # Initialize contracts
        self.game = self.w3.eth.contract(address=game_address, abi=game_abi)
        self.token = self.w3.eth.contract(address=token_address, abi=token_abi)

        # Store addresses
        self.game_address = game_address
        self.token_address = token_address

    def get_permit_signature(self, user_key, spender, amount, deadline):
        """Generate EIP712 permit signature"""
        user = Account.from_key(user_key)

        # Get token details
        name = self.token.functions.name().call()
        nonce = self.token.functions.nonces(user.address).call()

        # Get contract's DOMAIN_SEPARATOR for comparison
        contract_domain_separator = self.token.functions.DOMAIN_SEPARATOR().call()
        print("\nContract DOMAIN_SEPARATOR:", contract_domain_separator.hex())

        # EIP2612 permit data - match Solidity's encoding exactly
        domain_type_hash = self.w3.keccak(
            text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        )
        print("\nDomain components:")
        print("type_hash:", domain_type_hash.hex())
        print("name:", name)
        print("chainId:", self.w3.eth.chain_id)
        print("verifyingContract:", self.token_address)

        # Match Solidity's keccak256(bytes(string))
        name_hash = self.w3.keccak(text=name)
        version_hash = self.w3.keccak(text="1")
        print("name_hash:", name_hash.hex())
        print("version_hash:", version_hash.hex())

        # Match Solidity's abi.encode
        domain_separator = self.w3.keccak(
            encode(
                ["bytes32", "bytes32", "bytes32", "uint256", "address"],
                [
                    domain_type_hash,
                    name_hash,
                    version_hash,
                    self.w3.eth.chain_id,
                    self.token_address,
                ],
            )
        )
        print("\nCalculated DOMAIN_SEPARATOR:", domain_separator.hex())

        # Create permit digest - match Solidity's encoding
        permit_type_hash = self.w3.keccak(
            text="Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        )

        # Match Solidity's abi.encode
        struct_hash = self.w3.keccak(
            encode(
                ["bytes32", "address", "address", "uint256", "uint256", "uint256"],
                [
                    permit_type_hash,
                    user.address,
                    spender,
                    amount,
                    nonce,
                    deadline,
                ],
            )
        )

        # Final digest - match Solidity's encoding
        digest = self.w3.keccak(b"\x19\x01" + domain_separator + struct_hash)

        # Sign the digest
        signed = Account._sign_hash(digest, user_key)

        return {"v": signed.v, "r": signed.r, "s": signed.s, "deadline": deadline}

    def get_toss_signature(self, user_key, amount, token_price, toss_result, deadline):
        """Generate EIP712 toss signature"""
        user = Account.from_key(user_key)
        nonce = self.game.functions.nonces(user.address).call()

        # Create domain separator
        domain_type_hash = self.w3.keccak(
            text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        )
        print("\nDomain components:")
        print("type_hash:", domain_type_hash.hex())
        print("name: TossGame")
        print("chainId:", self.w3.eth.chain_id)
        print("verifyingContract:", self.game_address)

        # Match Solidity's keccak256(bytes(string))
        name_hash = self.w3.keccak(text="TossGame")
        version_hash = self.w3.keccak(text="1")
        print("name_hash:", name_hash.hex())
        print("version_hash:", version_hash.hex())

        # Match Solidity's abi.encode
        domain_separator = self.w3.keccak(
            encode(
                ["bytes32", "bytes32", "bytes32", "uint256", "address"],
                [
                    domain_type_hash,
                    name_hash,
                    version_hash,
                    self.w3.eth.chain_id,
                    self.game_address,
                ],
            )
        )
        print("\nCalculated DOMAIN_SEPARATOR:", domain_separator.hex())

        # Create toss digest
        toss_type_hash = self.w3.keccak(
            text="TossCoin(address user,address token,uint256 tokenAmount,uint256 tokenPrice,uint256 nonce,uint256 deadline,bool tossResult)"
        )

        # Match Solidity's abi.encode
        struct_hash = self.w3.keccak(
            encode(
                [
                    "bytes32",
                    "address",
                    "address",
                    "uint256",
                    "uint256",
                    "uint256",
                    "uint256",
                    "bool",
                ],
                [
                    toss_type_hash,
                    user.address,
                    self.token_address,
                    amount,
                    token_price,
                    nonce,
                    deadline,
                    toss_result,
                ],
            )
        )

        # Final digest - match Solidity's encoding
        digest = self.w3.keccak(b"\x19\x01" + domain_separator + struct_hash)

        # Sign the digest
        signed = Account._sign_hash(digest, user_key)

        return {
            "v": signed.v,
            "r": signed.r,
            "s": signed.s,
            "deadline": deadline,
            "nonce": nonce,
        }

    def deposit_with_permit(self, user_address, amount, token_price, user_signature):
        """
        Submit deposit with permit on behalf of user
        """
        # Create tuple matching the struct in the contract
        params = (
            user_address,  # address user
            self.token_address,  # address token
            amount,  # uint256 tokenAmount
            token_price,  # uint256 tokenPrice
            user_signature["deadline"],  # uint256 deadline
            user_signature["v"],  # uint8 v
            Web3.to_bytes(user_signature["r"]),  # bytes32 r
            Web3.to_bytes(user_signature["s"]),  # bytes32 s
        )

        tx = self.game.functions.depositTokenWithPermit(params).build_transaction(
            {
                "from": self.operator.address,
                "gas": 500000,
                "nonce": self.w3.eth.get_transaction_count(self.operator.address),
            }
        )

        signed_tx = self.w3.eth.account.sign_transaction(tx, self.operator.key)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        return self.w3.eth.wait_for_transaction_receipt(tx_hash)

    def toss_coin(self, user_address, amount, token_price, toss_result, user_signature):
        """
        Submit toss on behalf of user
        """
        # Create tuple matching the struct in the contract
        params = (
            user_address,  # address user
            self.token_address,  # address token
            amount,  # uint256 tokenAmount
            token_price,  # uint256 tokenPrice
            user_signature["nonce"],  # uint256 nonce
            user_signature["deadline"],  # uint256 deadline
            toss_result,  # bool tossResult
            user_signature["v"],  # uint8 v
            Web3.to_bytes(user_signature["r"]),  # bytes32 r
            Web3.to_bytes(user_signature["s"]),  # bytes32 s
        )

        tx = self.game.functions.tossCoinWithSignature(params).build_transaction(
            {
                "from": self.operator.address,
                "gas": 500000,
                "nonce": self.w3.eth.get_transaction_count(self.operator.address),
            }
        )

        signed_tx = self.w3.eth.account.sign_transaction(tx, self.operator.key)
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        return self.w3.eth.wait_for_transaction_receipt(tx_hash)

    def deposit(self, user_key, amount, token_price):
        """
        Submit deposit on behalf of user
        """
        user = Account.from_key(user_key)
        deadline = int(time.time()) + 3600  # 1 hour deadline

        # 1. Get permit signature for deposit
        permit_sig = self.get_permit_signature(
            user_key, self.game_address, amount, deadline
        )

        # 2. Submit deposit
        print("Submitting deposit...")
        deposit_receipt = self.deposit_with_permit(
            user.address, amount, token_price, permit_sig
        )
        print(
            f"Deposit successful! Tx hash: {deposit_receipt['transactionHash'].hex()}"
        )

    def toss(self, user_key, amount, token_price, toss_result):
        """
        Submit toss on behalf of user
        """
        user = Account.from_key(user_key)
        deadline = int(time.time()) + 3600  # 1 hour deadline

        # 1. Get toss signature
        toss_sig = self.get_toss_signature(
            user_key, amount, token_price, toss_result, deadline
        )

        # 2. Submit toss
        print("Submitting toss...")
        toss_receipt = self.toss_coin(
            user.address, amount, token_price, toss_result, toss_sig
        )
        print(f"Toss submitted! Tx hash: {toss_receipt['transactionHash'].hex()}")

    def deposit_and_toss(self, user_key, amount, token_price, toss_result):
        """Handle complete deposit and toss flow"""
        user = Account.from_key(user_key)
        deadline = int(time.time()) + 3600  # 1 hour deadline

        # 1. Get permit signature for deposit
        permit_sig = self.get_permit_signature(
            user_key, self.game_address, amount, deadline
        )

        # 2. Submit deposit
        print("Submitting deposit...")
        deposit_receipt = self.deposit_with_permit(
            user.address, amount, token_price, permit_sig
        )
        print(
            f"Deposit successful! Tx hash: {deposit_receipt['transactionHash'].hex()}"
        )

        # 3. Get toss signature
        toss_sig = self.get_toss_signature(
            user_key, amount, token_price, toss_result, deadline
        )

        # 4. Submit toss
        print("Submitting toss...")
        toss_receipt = self.toss_coin(
            user.address, amount, token_price, toss_result, toss_sig
        )
        print(f"Toss submitted! Tx hash: {toss_receipt['transactionHash'].hex()}")


def main():
    load_dotenv()

    # Load configuration from environment
    RPC_URL = os.getenv("RPC_URL", "http://localhost:8545")
    OPERATOR_KEY = os.getenv("OPERATOR_KEY")
    GAME_ADDRESS = os.getenv("GAME_ADDRESS")
    TOKEN_ADDRESS = os.getenv("TOKEN_ADDRESS")

    # Initialize operator
    operator = TossGameOperator(RPC_URL, OPERATOR_KEY, GAME_ADDRESS, TOKEN_ADDRESS)

    # Get user inputs
    user_key = os.getenv("USER_KEY")
    # Fixed token price for demo (in practice, get from oracle)
    token_price = Web3.to_wei(0.00000287528, "ether")  # scaled by 1e18

    # Execute deposit
    amount = 10000
    amount_wei = Web3.to_wei(amount, "ether")
    operator.deposit(user_key, amount_wei, token_price)

    # Execute toss
    amount = 100
    amount_wei = Web3.to_wei(amount, "ether")
    toss_result = input("Enter toss prediction (heads/tails): ").lower() == "heads"
    operator.toss(user_key, amount_wei, token_price, toss_result)


if __name__ == "__main__":
    main()
