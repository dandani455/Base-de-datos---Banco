-- Bootstrap del contenedor PostgreSQL (docker-entrypoint-initdb.d).
-- Se ejecuta UNA vez, al crear el volumen vacio, conectado a la BD "banco".
-- Alcance deliberadamente minimo: solo la zona horaria de la BD. NO crea tablas, funciones ni roles
-- (el esquema se aplica con db/sql/*.sql desde pgAdmin o con "ctl apply").
ALTER DATABASE banco SET timezone TO 'America/Bogota';
