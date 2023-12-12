# backup.sh
Script fait pour créer des dumps de base de données, dumps qui seront eux-mêmes sauvegardés par la sauvegarde du serveur.

Le script gère un système de lock pour éviter de lancer deux sauvegardes en parallèle, et génèrer un log de sauvegarde qui est envoyé par email en cas d'erreur.

## Prérequis
- identifier le type de BDD :
  - MySQL / MariaDB
  - PostgreSQL
  - MongoDB
  - LDAP
  - Prometheus (snapshot)
  - Xenserver (dump de la base et des metadatas des SR LVM)
  - archivage de fichiers avec rotation à chaque exécution du script
- identifier le type d'installation : service système ou dans un conteneur Docker
- définir le nombre de sauvegardes à conserver (sauvegarde unique ou historique sur x jours)

## Configuration
Les variables "globales" (non spécifique à chaque serveur) sont à configurer sont au début du script :
```
# Mail
DEST="CHANGEME@EXAMPLE.INVALID"
RETURNPATH="${DEST}"
SENDMAIL_OPTIONS="-t -f\"${RETURNPATH}\""
```

Pour l'archivage de fichiers / sites web :
```
#variables rsync
HOMEWWW_DIR="/var/www" # répertoire source
FILES_DEST="/home/backup/sites" # répertoire d'archivage
```

Le nettoyage des anciens dumps :
```
#argument de la commande find pour la purge des dumps plus vieux que:
# 3h =>clean_argument="-mmin +180"
#8 jours:
clean_argument="-mtime +8"
```

Les variables spécifiques serveur par serveur sont à définir dans des fichiers tiers :
- un fichier `backuprc` pour les options MySQL/MariaDB/PostgreSQL et Prometheus
- des fichiers backuprc_docker_mysql / backuprc_docker_mariadb / backuprc_docker_postgres / backuprc_docker_ldap / backuprc_docker_mongo pour préciser les caractéristiques des Docker

Ces fichiers backuprc_xxx sont des fichiers texte dont le format est le suivant (une ligne pour chaque conteneur Docker) :

Format de backuprc_docker_postgres : ```<CONTAINER_NAME>```

Ou si le user par défaut a été modifié : ```<CONTAINER_NAME>:<pgdefaultuser>:<pgdefaultdatabase>```

Format de backuprc_docker_mysql / backuprc_docker_mariadb / backuprc_docker_mongo : ```<CONTAINER_NAME>:<backupuser>:<backuppassword>```

Format de backuprc_docker_ldap : ```<CONTAINER_NAME>```

## Utilisation
Le script peut être lancé en cron.
Exemples :

- lancer un dump des bases PostgreSQL Docker tous les soirs à 23h
```
0 23 * * * root /root/tache.cron/backup.sh docker_postgres
```

- lancer un dump des bases PostgreSQL et MariadDB tous les dimanches (jour 7) à 9h
```
0 9 * * 7 root /root/tache.cron/backup.sh docker_postgres docker_mariadb
```

- lancer la création d'un snapshot prometheus toutes les 6h

```
0 */6 * * * root /root/tache.cron/backup.sh prometheus
```

Il est possible de le lancer à la main, voir ./backup.sh --help pour plus d'infos.
