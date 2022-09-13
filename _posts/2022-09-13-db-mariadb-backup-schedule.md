---
layout: post
title:  "Cấu hình backup định kỳ cho MariaDB"
description: "Cấu hình backup định kỳ cho MariaDB thông qua shell script"
tags: db mariadb backup
---

> Sử dụng shell script ở DB để lập lịch backup sẽ tối ưu hơn là thông qua code

> Ở đây ta đang thực hiện back full database, chưa thực hiện backup incremental

## 1. Tạo user MariaDB để thực hiện backup

Sử dụng user root, đăng nhập vào DB:

```shell
mysql -u root -p
```

Tạo user riêng cho công việc backup, sử dụng random pass ```Fq6BnMU2```

```shell
GRANT LOCK TABLES, SELECT, SHOW VIEW, REPLICATION CLIENT ON *.* TO 'db_user_backups'@'%' IDENTIFIED BY 'Fq6BnMU2';

SET GLOBAL log_bin_trust_function_creators = 1;
```

## 2. Tạo thư mục backup & biến môi trường

```shell
# create backup directory with environment and log file
sudo mkdir /backups && cd /backups
sudo touch .env db-backup.sh db-backup.log
sudo chmod -R 775 /backups
sudo chmod -R g+s /backups
sudo chmod +x db-backup.sh

# add mysql backup user credentials into environment file
echo "export MYSQL_USER=db_user_backups" > /backups/.env
echo "export MYSQL_PASS=Fq6BnMU2" >> /backups/.env
```

## 3. Tạo script để backup database

```shell
BKUP_DIR="/backups"

# create backup file names
BKUP_NAME="`date +%Y%m%d%H%M`-backup-sdscrm.sql.gz"

# get backup users credentials
source $BKUP_DIR/.env

# create backups
mysqldump --routines -u ${MYSQL_USER} -p${MYSQL_PASS} sdscrm | gzip > ${BKUP_DIR}/${BKUP_NAME}

```

Một số điểm lưu ý:
* File backup được tạo theo timestamp
* Sử dụng thông tin accoun từ file môi trường ```/backup/.env```
* Sử dụng Gzip để nén backup file

## 4. Cấu hình cho cron job

Ta cấu hình cron chạy vào ```02:00 AM``` hằng ngày với cron expression ```0 2 * * *```

```shell
crontab -e
```

Thêm dòng mới như dưới đây, lưu lại:

```shell
0 2 * * * /usr/bin/env bash /backups/db-backup.sh &>> /backups/db-backup.log
```

**Done!**