# Collector.shop — mémo de commandes

Marketplace C2C d'objets de collection.
Backend C++ 20 (Drogon), PostgreSQL 16, orchestré par Docker Compose.

> Les commandes sont données pour **PowerShell sous Windows**.
> Quand une commande enchaîne des outils Unix (`grep`, `|`, `&&`), elle est
> passée au conteneur via `sh -c "..."` plutôt qu'exécutée par PowerShell.

---

## 1. Prérequis

| Élément | Vérification |
|---|---|
| Virtualisation activée | Gestionnaire des tâches → Performance → CPU → ligne « Virtualisation » |
| Docker Desktop | `docker version` doit afficher un bloc **Client** *et* un bloc **Server** |
| WSL 2 | `wsl --status` → version par défaut 2 |

Si la virtualisation est désactivée : BIOS/UEFI → `Intel Virtualization Technology`
(Intel) ou `SVM Mode` (AMD). Sur carte Gigabyte, `F2` pour passer en Advanced Mode,
puis `Settings → Miscellaneous`. Faire un **arrêt complet**, pas un redémarrage.

---

## 2. Structure du projet

```
CollectorCesi/
├─ CMakeLists.txt              projet racine, find_package(Drogon)
├─ conanfile.txt               dépendances + générateurs
├─ docker-compose.yml
├─ .env                        secrets locaux — NE PAS COMMITER
├─ .dockerignore
├─ db/
│  └─ init/
│     └─ 01_schema.sql.old         exécuté au 1er démarrage de postgres
└─ services/
   └─ catalogue/
      ├─ CMakeLists.txt        add_executable(catalogue ...)
      ├─ Dockerfile            multi-stage : builder + runtime
      └─ src/
         └─ main.cpp
```

Fichier `.env` (jamais versionné) :

```
POSTGRES_PASSWORD=changeme
```

---

## 3. Cycle quotidien

```powershell
# Démarrer la pile complète
docker compose up -d

# Suivre les logs
docker compose logs -f catalogue

# État des services
docker compose ps

# Arrêter (les données de la base sont conservées)
docker compose down
```

Test de vie du service :

```powershell
curl http://localhost:8080/health
# {"service":"catalogue","status":"ok"}
```

---

## 4. Build

```powershell
# Build normal (le cache Conan est réutilisé)
docker compose build

# Build complet — obligatoire après modification de conanfile.txt
docker compose build --no-cache

# Voir la sortie détaillée de chaque étape
docker compose build --progress=plain

# Construire et relancer d'un coup
docker compose up --build
```

> Un build qui recompile Drogon prend **15 à 20 minutes**.
> Un build de quelques secondes signifie que tout venait du cache — si vous
> attendiez une recompilation, c'est que votre modification n'a pas été prise
> en compte.

### Image de développement (pour CLion)

L'image `:dev` est l'image **runtime** : elle ne contient ni compilateur, ni
CMake, ni GDB. Pour l'IDE, il faut l'étape `builder` :

```powershell
docker build -f services/catalogue/Dockerfile --target builder -t collector/catalogue:builder .
```

---

## 5. Base de données

```powershell
# Ouvrir une session psql
docker compose exec postgres psql -U collector -d collector

# Lister les tables (11 attendues)
docker compose exec postgres psql -U collector -d collector -c "\dt"

# Lister les vues matérialisées
docker compose exec postgres psql -U collector -d collector -c "\dm"

# Décrire une table
docker compose exec postgres psql -U collector -d collector -c "\d article"

# Rafraîchir les statistiques de prix (règle des 3 sigma)
docker compose exec postgres psql -U collector -d collector -c "REFRESH MATERIALIZED VIEW category_price_stats"
```

### Rejouer le schéma

`db/init/` n'est exécuté que sur une base **vide**. Après modification du SQL :

```powershell
docker compose down -v      # -v détruit le volume, donc les données
docker compose up -d
docker compose exec postgres psql -U collector -d collector -c "\dt"
```

### Sauvegarde / restauration

```powershell
docker compose exec postgres pg_dump -U collector collector > backup.sql
Get-Content backup.sql | docker compose exec -T postgres psql -U collector -d collector
```

---

## 6. Inspection des conteneurs

```powershell
# Shell dans le service
docker compose exec catalogue sh

# Bibliothèques dynamiques manquantes
docker run --rm collector/catalogue:dev sh -c "ldd /usr/local/bin/catalogue"
docker run --rm collector/catalogue:dev sh -c "ldd /usr/local/bin/catalogue | grep -iE 'pq|not found'"

# Contenu de l'installation Conan dans l'image de build
docker run --rm collector/catalogue:builder sh -c "ls /opt/conan"

# Taille des images
docker images collector/catalogue
```

---

## 7. Nettoyage

```powershell
# Conteneurs orphelins lancés hors Compose
docker ps -a
docker rm -f <nom_du_conteneur>

# Tout arrêter et supprimer les volumes du projet
docker compose down -v

# Récupérer de l'espace disque (images, caches, réseaux inutilisés)
docker system prune -a
```

> `docker system prune -a` supprime le cache de build : le prochain build
> recompilera Drogon intégralement.

---

## 8. CLion — développer dans le conteneur

Drogon n'existe que dans l'image Docker. Sans cette configuration, CLion
affiche « Cannot resolve symbol 'drogon' ».

1. Construire l'image builder (voir §4).
2. `Settings → Build, Execution, Deployment → Toolchains → +` → **Docker**
   Image : `collector/catalogue:builder`
   CMake, Build Tool, C/C++ Compiler et GDB doivent être détectés.
3. `Settings → CMake` :
    - Toolchain : **Docker**
    - Build type : **Release**
    - CMake options : `-DCMAKE_TOOLCHAIN_FILE=/opt/conan/conan_toolchain.cmake`
4. `Tools → CMake → Reset Cache and Reload Project`

> **Build type Release obligatoire.** Les paquets Conan de l'image sont
> compilés en Release ; un profil Debug ne trouvera pas Drogon. Pour déboguer,
> il faut générer un second jeu de paquets Debug dans l'image builder.

---

## 9. Dépannage

### `request returned 500 Internal Server Error for API route ... _ping`
Le daemon Docker ne tourne pas. Voir §1 (virtualisation, WSL 2).

### `Could not find toolchain file: /opt/conan/conan_toolchain.cmake`
Trois causes possibles :

- La section `[generators]` manque dans `conanfile.txt`. Elle doit contenir
  `CMakeDeps` et `CMakeToolchain`.
- Une section `[layout] cmake_layout` est présente : elle déplace les fichiers
  vers `/opt/conan/build/Release/generators/`. **La retirer** — elle est utile
  en local, inutile et gênante dans un conteneur.
- Pour localiser le fichier réellement généré :
  ```powershell
  docker run --rm collector/catalogue:builder sh -c "find /opt/conan -name conan_toolchain.cmake"
  ```

### `Error 13 creating path ./uploads/tmp/XX/: Permission denied`
Drogon crée son arborescence d'uploads en chemin relatif, et l'utilisateur
non-root n'a pas les droits. Dans le Dockerfile, avant `USER 10001` :

```dockerfile
RUN mkdir -p /app/uploads && chown -R 10001:10001 /app
WORKDIR /app
```

Le service fonctionne malgré ces erreurs — elles sont bruyantes, pas bloquantes.

### `Did not find any relations` alors que postgres est healthy
Le script d'init n'a pas été joué. Vérifier le montage :

```powershell
docker compose exec postgres ls -la /docker-entrypoint-initdb.d/
docker compose logs postgres | Select-String -Pattern "error","01_schema"
```

Puis rejouer avec `docker compose down -v`.

### `grep : Le terme «grep» n'est pas reconnu`
PowerShell n'a pas `grep`. Deux options :

```powershell
docker run --rm <image> sh -c "commande | grep motif"
docker run --rm <image> commande | Select-String -Pattern "motif"
```

### Le conteneur redémarre en boucle
Une bibliothèque manque dans l'image runtime.

```powershell
docker compose logs catalogue
docker run --rm collector/catalogue:dev sh -c "ldd /usr/local/bin/catalogue | grep 'not found'"
```

Ajouter le paquet manquant (`libpq5` pour PostgreSQL) au `apt-get install` de
l'étape runtime.

### Le service tourne mais `curl` ne répond pas
Drogon écoute probablement sur `127.0.0.1`. Depuis un conteneur, il faut
écouter sur `0.0.0.0`, sinon le port publié ne sert à rien.

---

## 10. Rappels

- `.env` et les secrets ne sont **jamais** commités. Le pipeline exécute un
  scan de secrets qui échouera sinon.
- Dans un réseau Compose, les services s'adressent par leur **nom**
  (`DB_HOST=postgres`), jamais par `localhost`.
- Le `depends_on` avec `condition: service_healthy` est indispensable : sans
  lui, le service C++ démarre avant que PostgreSQL accepte les connexions.
- Retirer les commandes de débogage (`find`, `ls`) du Dockerfile avant de
  commiter.