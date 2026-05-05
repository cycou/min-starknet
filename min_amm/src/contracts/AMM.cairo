// =============================================
// AMM - Automated Market Maker (Swap)
// Ecrit en Cairo 2 - Compatible Starknet 2025
// Basé sur min-starknet par Argent Labs
// Modernisé et vérifié par Claude
// =============================================

#[starknet::contract]
mod AMM {
    use starknet::get_caller_address;
    use starknet::ContractAddress;
    use starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess,
        StoragePathEntry, Map
    };

    // =============================================
    // CONSTANTES - Limites de sécurité
    // =============================================
    const BALANCE_UPPER_BOUND: u128 = 1073741824_u128; // Max tokens dans l'AMM (2^30)
    const POOL_UPPER_BOUND: u128 = 1048576_u128;       // Max tokens dans la pool (2^20)
    const ACCOUNT_BALANCE_BOUND: u128 = 104857_u128;   // Max tokens par compte

    // =============================================
    // TYPES DE TOKENS (seulement 2 pour la simplicité)
    // =============================================
    const TOKEN_TYPE_A: felt252 = 1;
    const TOKEN_TYPE_B: felt252 = 2;

    // =============================================
    // STOCKAGE - Variables du contrat
    // =============================================
    #[storage]
    struct Storage {
        // Solde de chaque compte pour chaque token
        account_balance: Map<(ContractAddress, felt252), u128>,
        // Solde de la pool pour chaque token
        pool_balance: Map<felt252, u128>,
    }

    // =============================================
    // EVENEMENTS - Pour suivre les transactions
    // =============================================
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SwapExecuted: SwapExecuted,
        PoolInitialized: PoolInitialized,
        TokensAdded: TokensAdded,
    }

    #[derive(Drop, starknet::Event)]
    struct SwapExecuted {
        #[key]
        account: ContractAddress,
        token_from: felt252,
        token_to: felt252,
        amount_from: u128,
        amount_to: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct PoolInitialized {
        token_a_amount: u128,
        token_b_amount: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct TokensAdded {
        #[key]
        account: ContractAddress,
        token_a_amount: u128,
        token_b_amount: u128,
    }

    // =============================================
    // FONCTIONS DE LECTURE (view)
    // =============================================
    #[abi(embed_v0)]
    impl AMMImpl of super::IAMM<ContractState> {

        // Retourne le solde d'un compte pour un token donné
        fn get_account_token_balance(
            self: @ContractState,
            account: ContractAddress,
            token_type: felt252
        ) -> u128 {
            self.account_balance.entry((account, token_type)).read()
        }

        // Retourne le solde de la pool pour un token donné
        fn get_pool_token_balance(
            self: @ContractState,
            token_type: felt252
        ) -> u128 {
            self.pool_balance.entry(token_type).read()
        }

        // =============================================
        // FONCTIONS D'ECRITURE (external)
        // =============================================

        // Initialise la pool avec des tokens (à appeler une seule fois)
        fn init_pool(ref self: ContractState, token_a: u128, token_b: u128) {
            assert(token_a < POOL_UPPER_BOUND, 'Token A: depasse le maximum');
            assert(token_b < POOL_UPPER_BOUND, 'Token B: depasse le maximum');

            self.pool_balance.entry(TOKEN_TYPE_A).write(token_a);
            self.pool_balance.entry(TOKEN_TYPE_B).write(token_b);

            self.emit(PoolInitialized { token_a_amount: token_a, token_b_amount: token_b });
        }

        // Ajoute des tokens de démonstration au compte de l'appelant
        fn add_demo_token(
            ref self: ContractState,
            token_a_amount: u128,
            token_b_amount: u128
        ) {
            let account = get_caller_address();

            self._modify_account_balance(account, TOKEN_TYPE_A, token_a_amount, true);
            self._modify_account_balance(account, TOKEN_TYPE_B, token_b_amount, true);

            self.emit(TokensAdded {
                account,
                token_a_amount,
                token_b_amount
            });
        }

        // FONCTION PRINCIPALE : Échanger des tokens
        // token_from = le token que tu envoies (1 = Token A, 2 = Token B)
        // amount_from = la quantité que tu envoies
        fn swap(ref self: ContractState, token_from: felt252, amount_from: u128) {
            let account = get_caller_address();

            // Vérifier que le token est valide
            assert(
                token_from == TOKEN_TYPE_A || token_from == TOKEN_TYPE_B,
                'Token non autorise dans la pool'
            );

            // Vérifier que le montant est valide
            assert(amount_from < BALANCE_UPPER_BOUND, 'Montant trop eleve');
            assert(amount_from > 0_u128, 'Montant doit etre positif');

            // Vérifier que l'utilisateur a assez de tokens
            let account_balance = self.account_balance.entry((account, token_from)).read();
            assert(account_balance >= amount_from, 'Solde insuffisant');

            // Effectuer l'échange
            let token_to = if token_from == TOKEN_TYPE_A {
                TOKEN_TYPE_B
            } else {
                TOKEN_TYPE_A
            };

            let amount_to = self._do_swap(account, token_from, token_to, amount_from);

            self.emit(SwapExecuted {
                account,
                token_from,
                token_to,
                amount_from,
                amount_to,
            });
        }
    }

    // =============================================
    // FONCTIONS INTERNES (privées)
    // =============================================
    #[generate_trait]
    impl InternalImpl of InternalTrait {

        // Modifie le solde d'un compte pour un token donné
        fn _modify_account_balance(
            ref self: ContractState,
            account: ContractAddress,
            token_type: felt252,
            amount: u128,
            add: bool
        ) {
            let current_balance = self.account_balance.entry((account, token_type)).read();

            let new_balance = if add {
                let result = current_balance + amount;
                assert(result < BALANCE_UPPER_BOUND, 'Depasse le maximum autorise');
                result
            } else {
                assert(current_balance >= amount, 'Solde insuffisant');
                current_balance - amount
            };

            self.account_balance.entry((account, token_type)).write(new_balance);
        }

        // Effectue l'échange entre le compte et la pool
        // Formule : amount_to = (pool_to * amount_from) / (pool_from + amount_from)
        // C'est la formule classique x*y=k utilisée par Uniswap
        fn _do_swap(
            ref self: ContractState,
            account: ContractAddress,
            token_from: felt252,
            token_to: felt252,
            amount_from: u128
        ) -> u128 {
            // Lire les soldes actuels de la pool
            let pool_from = self.pool_balance.entry(token_from).read();
            let pool_to = self.pool_balance.entry(token_to).read();

            // Vérifier que la pool a des tokens
            assert(pool_from > 0_u128, 'Pool vide pour token_from');
            assert(pool_to > 0_u128, 'Pool vide pour token_to');

            // Calculer le montant à recevoir (formule x*y=k)
            let amount_to = (pool_to * amount_from) / (pool_from + amount_from);
            assert(amount_to > 0_u128, 'Montant recu trop faible');

            // Mettre à jour le solde du compte
            self._modify_account_balance(account, token_from, amount_from, false);
            self._modify_account_balance(account, token_to, amount_to, true);

            // Mettre à jour les soldes de la pool
            self.pool_balance.entry(token_from).write(pool_from + amount_from);
            self.pool_balance.entry(token_to).write(pool_to - amount_to);

            amount_to
        }
    }
}

// =============================================
// INTERFACE - Définit les fonctions publiques
// =============================================
#[starknet::interface]
trait IAMM<TContractState> {
    fn get_account_token_balance(
        self: @TContractState,
        account: starknet::ContractAddress,
        token_type: felt252
    ) -> u128;

    fn get_pool_token_balance(
        self: @TContractState,
        token_type: felt252
    ) -> u128;

    fn init_pool(ref self: TContractState, token_a: u128, token_b: u128);

    fn add_demo_token(
        ref self: TContractState,
        token_a_amount: u128,
        token_b_amount: u128
    );

    fn swap(ref self: TContractState, token_from: felt252, amount_from: u128);
}
