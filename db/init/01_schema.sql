-- =====================================================================
-- Collector.shop — schéma initial
-- PostgreSQL 16
--
-- Couverture : E1 comptes et rôles · E2 catalogue et boutiques
--              E3 mise en ligne et contrôle · E4 paiement et commission
--              E5 espace personnel et notation · E9 anti-fraude
--
-- Exécuté automatiquement par l'image postgres au premier démarrage
-- (montage dans /docker-entrypoint-initdb.d).
-- =====================================================================

SET client_min_messages = warning;

-- ---------------------------------------------------------------------
-- Types métier
-- ---------------------------------------------------------------------

-- Statuts du cycle de vie d'une annonce (US-10, US-11, CA-1 à CA-3)
CREATE TYPE article_status AS ENUM (
    'BROUILLON',
    'EN_CONTROLE',
    'PUBLIE',
    'EN_REVUE',
    'REJETE',
    'VENDU',
    'RETIRE'
);

CREATE TYPE order_status AS ENUM (
    'EN_ATTENTE_PAIEMENT',
    'PAYEE',
    'EXPEDIEE',
    'RECUE',
    'ANNULEE',
    'REMBOURSEE'
);

CREATE TYPE fraud_alert_kind AS ENUM (
    'PRIX_ANORMAL',
    'VENDEUR_SUSPECT',
    'CONTENU_SIGNALE'
);

CREATE TYPE fraud_alert_status AS ENUM (
    'OUVERTE',
    'EN_COURS',
    'CONFIRMEE',
    'REJETEE'
);

-- ---------------------------------------------------------------------
-- Fonction utilitaire : horodatage de modification
-- ---------------------------------------------------------------------

CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- E1 · Comptes, rôles et authentification
-- =====================================================================

-- Aucun mot de passe n'est stocké : l'identité est portée par Keycloak.
-- keycloak_sub est la revendication « sub » du jeton JWT.
CREATE TABLE app_user (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    keycloak_sub    uuid NOT NULL UNIQUE,
    display_name    text NOT NULL,
    -- Conservé pour les notifications par e-mail (US-28) uniquement.
    -- N'est jamais exposé à un autre utilisateur (US-23).
    email           text NOT NULL UNIQUE,
    is_seller       boolean NOT NULL DEFAULT false,   -- US-03
    locale          text NOT NULL DEFAULT 'fr-FR',    -- US-36
    suspended_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_app_user_keycloak_sub ON app_user (keycloak_sub);

CREATE TRIGGER trg_app_user_updated
    BEFORE UPDATE ON app_user
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- E2 · Catalogue, catégories et boutiques
-- =====================================================================

-- Les catégories ne sont créées que par l'administrateur (US-05).
-- Cette règle est portée par l'application ; la base garantit l'unicité.
CREATE TABLE category (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    label       text NOT NULL,
    parent_id   uuid REFERENCES category (id) ON DELETE RESTRICT,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_category_parent ON category (parent_id);

-- Un vendeur peut ouvrir plusieurs boutiques (US-08) mais reste
-- identifié comme vendeur particulier (US-09).
CREATE TABLE shop (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id    uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner_id, name),
    -- Cible de la cle etrangere composite posee sur article :
    -- garantit qu'un article ne peut etre rattache qu'a une boutique
    -- appartenant a son propre vendeur.
    UNIQUE (id, owner_id)
);

CREATE INDEX idx_shop_owner ON shop (owner_id);

CREATE TRIGGER trg_shop_updated
    BEFORE UPDATE ON shop
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =====================================================================
-- E3 · Mise en ligne et contrôle automatisé
-- =====================================================================

CREATE TABLE article (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seller_id       uuid NOT NULL REFERENCES app_user (id) ON DELETE RESTRICT,
    shop_id         uuid,
    category_id     uuid NOT NULL REFERENCES category (id) ON DELETE RESTRICT,

    title           text NOT NULL,
    description     text NOT NULL,

    -- Jamais de type flottant sur de la monnaie.
    price_cents     bigint NOT NULL CHECK (price_cents > 0),
    shipping_cents  bigint NOT NULL DEFAULT 0 CHECK (shipping_cents >= 0),
    currency        char(3) NOT NULL DEFAULT 'EUR',

    -- Attributs variables selon la catégorie : année, état, tirage,
    -- édition… Le contexte impose des objets très hétérogènes.
    attributes      jsonb NOT NULL DEFAULT '{}'::jsonb,

    status          article_status NOT NULL DEFAULT 'EN_CONTROLE',
    -- Score renvoyé par svc-controle (CA-2, CA-3)
    anomaly_score   numeric(6,3),
    reviewed_at     timestamptz,

    published_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    -- Un article publié doit avoir une date de publication.
    CONSTRAINT chk_published_at
        CHECK (status <> 'PUBLIE' OR published_at IS NOT NULL),

    -- Cle composite : la boutique doit appartenir au vendeur de l'article.
    -- MATCH SIMPLE : la contrainte ne s'applique pas si shop_id est NULL,
    -- donc un article sans boutique reste autorise.
    CONSTRAINT fk_article_shop_owner
        FOREIGN KEY (shop_id, seller_id)
        REFERENCES shop (id, owner_id) ON DELETE RESTRICT
);

-- Le catalogue public ne lit que les articles publiés : index partiel.
CREATE INDEX idx_article_public
    ON article (category_id, published_at DESC)
    WHERE status = 'PUBLIE';

CREATE INDEX idx_article_seller    ON article (seller_id);
CREATE INDEX idx_article_status    ON article (status);
CREATE INDEX idx_article_attrs     ON article USING gin (attributes);

CREATE TRIGGER trg_article_updated
    BEFORE UPDATE ON article
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Chaque article publié doit avoir des photos (exigence du contexte).
CREATE TABLE article_photo (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id  uuid NOT NULL REFERENCES article (id) ON DELETE CASCADE,
    -- Clé de l'objet dans le stockage, jamais le binaire en base.
    storage_key text NOT NULL,
    position    smallint,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (article_id, position)
);

CREATE INDEX idx_article_photo_article ON article_photo (article_id);

-- Sans cela, deux insertions sans position explicite violent la
-- contrainte d'unicite. La position est attribuee a la suite.
CREATE FUNCTION assign_photo_position() RETURNS trigger AS $$
BEGIN
    IF NEW.position IS NULL THEN
        SELECT coalesce(max(position) + 1, 0) INTO NEW.position
        FROM article_photo WHERE article_id = NEW.article_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_article_photo_position
    BEFORE INSERT ON article_photo
    FOR EACH ROW EXECUTE FUNCTION assign_photo_position();

-- ---------------------------------------------------------------------
-- Collecte des variations de prix (US-12, US-13, CA-4)
-- Le contexte impose que « en cas de variation du prix, l'information
-- doit être collectée ». L'historique est tenu par la base ; la
-- publication de l'événement price.changed reste à la charge du service.
-- ---------------------------------------------------------------------

CREATE TABLE price_history (
    id              bigserial PRIMARY KEY,
    article_id      uuid NOT NULL REFERENCES article (id) ON DELETE CASCADE,
    old_price_cents bigint,
    new_price_cents bigint NOT NULL,
    changed_by      uuid REFERENCES app_user (id) ON DELETE SET NULL,
    changed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_price_history_article ON price_history (article_id, changed_at DESC);

CREATE FUNCTION record_price_change() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO price_history (article_id, old_price_cents, new_price_cents, changed_by)
        VALUES (NEW.id, NULL, NEW.price_cents, NEW.seller_id);
    ELSIF NEW.price_cents IS DISTINCT FROM OLD.price_cents THEN
        INSERT INTO price_history (article_id, old_price_cents, new_price_cents, changed_by)
        VALUES (NEW.id, OLD.price_cents, NEW.price_cents, NEW.seller_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_article_price_history
    AFTER INSERT OR UPDATE OF price_cents ON article
    FOR EACH ROW EXECUTE FUNCTION record_price_change();

-- ---------------------------------------------------------------------
-- Statistiques de prix par catégorie
-- Support de la règle des 3 écarts-types (CA-3). Rafraîchie
-- périodiquement plutôt que calculée à chaque soumission : le contrôle
-- doit répondre en moins de 2 secondes.
-- ---------------------------------------------------------------------

-- Garde-fou : avec un echantillon trop faible, l'ecart-type vaut 0 ou
-- NULL et la regle des 3 sigma classerait tout prix different de la
-- mediane en anomalie. stddev_cents reste NULL sous le seuil, et le
-- service de controle doit alors s'abstenir de conclure.
CREATE MATERIALIZED VIEW category_price_stats AS
SELECT
    category_id,
    count(*)                                                 AS sample_size,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY price_cents) AS median_cents,
    CASE WHEN count(*) >= 30 THEN stddev_samp(price_cents) END AS stddev_cents
FROM article
WHERE status IN ('PUBLIE', 'VENDU')
GROUP BY category_id;

CREATE UNIQUE INDEX idx_category_price_stats ON category_price_stats (category_id);

-- =====================================================================
-- E4 · Paiement, commission et livraison
-- =====================================================================

-- Le paiement passe obligatoirement par la plateforme (US-16).
-- Aucune donnée de carte n'est stockée : seule la référence du
-- prestataire certifié PCI-DSS est conservée.
CREATE TABLE purchase (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id          uuid NOT NULL REFERENCES article (id) ON DELETE RESTRICT,
    buyer_id            uuid NOT NULL REFERENCES app_user (id) ON DELETE RESTRICT,
    seller_id           uuid NOT NULL REFERENCES app_user (id) ON DELETE RESTRICT,

    -- Montants figés au moment de l'achat : un changement de prix
    -- ultérieur ne doit pas réécrire une transaction passée.
    item_cents          bigint NOT NULL CHECK (item_cents > 0),
    shipping_cents      bigint NOT NULL DEFAULT 0 CHECK (shipping_cents >= 0),
    commission_cents    bigint NOT NULL CHECK (commission_cents >= 0),
    commission_rate     numeric(5,4) NOT NULL DEFAULT 0.0500,   -- US-15
    total_cents         bigint NOT NULL CHECK (total_cents > 0),
    currency            char(3) NOT NULL DEFAULT 'EUR',

    status              order_status NOT NULL DEFAULT 'EN_ATTENTE_PAIEMENT',
    tracking_number     text,                                   -- US-17

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT chk_no_self_purchase CHECK (buyer_id <> seller_id),
    CONSTRAINT chk_total_coherent
        CHECK (total_cents = item_cents + shipping_cents)
);

-- Les objets de collection sont des pieces uniques : un article ne peut
-- faire l'objet que d'un achat actif a la fois. Une annulation ou un
-- remboursement libere l'article et autorise une nouvelle vente.
CREATE UNIQUE INDEX uniq_active_purchase_per_article
    ON purchase (article_id)
    WHERE status NOT IN ('ANNULEE', 'REMBOURSEE');

CREATE INDEX idx_purchase_buyer  ON purchase (buyer_id, created_at DESC);
CREATE INDEX idx_purchase_seller ON purchase (seller_id, created_at DESC);

CREATE TRIGGER trg_purchase_updated
    BEFORE UPDATE ON purchase
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Trace des échanges avec le prestataire de paiement.
-- provider_event_id porte l'idempotence des webhooks.
CREATE TABLE payment_event (
    id                  bigserial PRIMARY KEY,
    purchase_id         uuid NOT NULL REFERENCES purchase (id) ON DELETE CASCADE,
    provider            text NOT NULL,
    provider_event_id   text NOT NULL,
    event_type          text NOT NULL,
    payload             jsonb NOT NULL,
    received_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_event_id)
);

CREATE INDEX idx_payment_event_purchase ON payment_event (purchase_id);

-- =====================================================================
-- E5 · Espace personnel et notation
-- =====================================================================

-- On ne note que si l'on a transigé, et une seule fois par achat (US-20).
CREATE TABLE rating (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_id uuid NOT NULL REFERENCES purchase (id) ON DELETE CASCADE,
    author_id   uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    target_id   uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    score       smallint NOT NULL CHECK (score BETWEEN 1 AND 5),
    comment     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (purchase_id, author_id),
    CONSTRAINT chk_no_self_rating CHECK (author_id <> target_id)
);

CREATE INDEX idx_rating_target ON rating (target_id);

-- L'unicite ne suffit pas : sans ce controle, un utilisateur etranger
-- a la transaction peut noter n'importe qui.
CREATE FUNCTION check_rating_party() RETURNS trigger AS $$
DECLARE
    v_buyer  uuid;
    v_seller uuid;
BEGIN
    SELECT buyer_id, seller_id INTO v_buyer, v_seller
    FROM purchase WHERE id = NEW.purchase_id;

    IF NEW.author_id NOT IN (v_buyer, v_seller)
       OR NEW.target_id NOT IN (v_buyer, v_seller) THEN
        RAISE EXCEPTION
            'Notation refusee : auteur ou cible etranger a la transaction %',
            NEW.purchase_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_rating_party
    BEFORE INSERT OR UPDATE ON rating
    FOR EACH ROW EXECUTE FUNCTION check_rating_party();

-- Centres d'intérêt paramétrables (US-21), base des recommandations (E8)
-- et des notifications ciblées (US-26).
CREATE TABLE user_interest (
    user_id     uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    category_id uuid NOT NULL REFERENCES category (id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, category_id)
);

-- =====================================================================
-- E9 · Détection de fraude et d'anomalies
-- =====================================================================

-- Alimentée par svc-controle (scoring interne) ou par un outil externe :
-- le contexte n'a pas tranché entre développer et acheter.
CREATE TABLE fraud_alert (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        fraud_alert_kind NOT NULL,
    status      fraud_alert_status NOT NULL DEFAULT 'OUVERTE',
    article_id  uuid REFERENCES article (id) ON DELETE CASCADE,
    user_id     uuid REFERENCES app_user (id) ON DELETE CASCADE,
    score       numeric(6,3),
    -- Origine de l'alerte : 'svc-controle' ou nom de l'outil externe.
    source      text NOT NULL DEFAULT 'svc-controle',
    details     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,

    CONSTRAINT chk_alert_target
        CHECK (article_id IS NOT NULL OR user_id IS NOT NULL)
);

CREATE INDEX idx_fraud_alert_open
    ON fraud_alert (created_at DESC)
    WHERE status = 'OUVERTE';

CREATE INDEX idx_fraud_alert_article ON fraud_alert (article_id);

-- =====================================================================
-- Jeu de données minimal
-- =====================================================================

INSERT INTO category (slug, label) VALUES
    ('sneakers',      'Baskets en édition limitée'),
    ('posters',       'Posters dédicacés'),
    ('figurines',     'Figurines'),
    ('cassettes',     'Cassettes et supports vidéo'),
    ('bd',            'Bandes dessinées');
