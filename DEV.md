# Plataforma de desarrollo local

`docker-compose.dev.yml` levanta en local, sobre [Floci](https://floci.io/aws/) (emulador de AWS, MIT), un Cognito compartido y un API Gateway (HTTP API) con un Lambda authorizer delante de los microservicios `academic` y `notification`. El frontend (`UniFlow-Frontend`) inicia sesión contra el Hosted UI de Cognito y llama a los servicios a través del gateway. Solo para desarrollo.

Alcance: login desde el frontend y llamadas autenticadas a academic y notification. Las tareas viven en academic. Fuera de alcance: WebSocket / push en tiempo real, el resto de lambdas, terraform. Nota: el servicio NestJS `notification` es solo para desarrollo local; en AWS las notificaciones son 100% serverless (`lambdas/`: API REST en Lambdas + DynamoDB, push por WebSocket API, stack en `lambdas/terraform`) y el servicio NestJS no se despliega.

## Arquitectura

```
 Navegador (http://localhost:3000)  --- UniFlow-Frontend (vite)
   |  1. login: Hosted UI, Authorization Code + PKCE
   |  2. API: Authorization: Bearer <access token>
   v
 +------------------ Floci (floci/floci:2.3.0, :4566) ------------------+
 | Cognito  pool us-east-1_UniflowDev, client uniflow-spa, Hosted UI    |
 |          /cognito-idp/oauth2/authorize | login | oauth2/token | logout |
 | HTTP API "uniflow"  http://uniflow.execute-api.localhost.floci.io:4566|
 |   ruta -> Lambda authorizer (REQUEST, payload 2.0, simple response)  |
 |           contenedor Node 22 que arranca Floci (lambdas/http_authorizer)|
 |           valida firma RS256 con el JWKS del issuer                  |
 +--------------+----------------------------+--------------------------+
                | /api/academic/v2/*         | /api/notifications/v2/*
                v (prefijo recortado)        v (prefijo recortado)
        academic :3001 (Spring)       notification :3003 (NestJS)
                |                            |
           postgres :5432                mongo :27017
```

Red Docker `uniflow-dev`. Solo se publica el puerto `4566` de Floci; los servicios no se exponen al host.

## Servicios

| Servicio | Qué es | Puerto |
|---|---|---|
| `floci` | Emulador de AWS (Cognito, Lambda, API Gateway). Monta `/var/run/docker.sock` para arrancar el contenedor de la Lambda | `4566` en el host |
| `floci-init` | Tarea de un solo uso e idempotente (`docker/floci/init.sh`, imagen `amazon/aws-cli`): pool, dominio Hosted UI, client, usuarios, Lambda y HTTP API | - |
| `postgres` | Base de datos de academic (PostgreSQL 16; Flyway crea el esquema) | interno `5432` |
| `mongo` | Base de datos de notification (MongoDB 8) | interno `27017` |
| `academic` | `uniflow-academic-service`; revalida el JWT por su cuenta | interno `3001` |
| `notification` | `uniflow-notification-service`; no autentica, lo protege el gateway | interno `3003` |

Se usa un PostgreSQL normal en vez de RDS de Floci: para la app es equivalente, hay menos piezas y no queda un contenedor de RDS arrancado por Floci fuera del control de Compose. Notification usa MongoDB (no DynamoDB/SQS/SNS), por eso `floci-init` no crea recursos para él; el envío de email (SES) y push está desactivado (`EMAIL_ENABLED=false`, `PUSH_ENABLED=false`).

## Comandos

```bash
# Levantar (la primera vez construye las imágenes y descarga Floci, postgres, mongo y aws-cli)
docker compose -f docker-compose.dev.yml up -d --build
docker compose -f docker-compose.dev.yml logs floci-init     # bootstrap; termina con "done"

# Access token de un usuario de desarrollo (user-a o user-b); solo necesita curl y openssl
TOKEN=$(scripts/dev-token.sh user-a)
curl -H "Authorization: Bearer $TOKEN" http://uniflow.execute-api.localhost.floci.io:4566/api/academic/v2/periods

# Verificación de extremo a extremo (denegaciones, flujo periodo -> curso -> tarea, aislamiento, CORS)
scripts/dev-smoke.sh

# Parar y borrar contenedores, red y datos (incluida la Lambda que arrancó Floci)
docker compose -f docker-compose.dev.yml down -v
```

Usuarios (se crean con contraseña permanente; cámbialas con `USER_A_PASSWORD` / `USER_B_PASSWORD`):

| Usuario | Contraseña |
|---|---|
| `user-a@uniflow.local` | `UserA-Dev-Passw0rd` |
| `user-b@uniflow.local` | `UserB-Dev-Passw0rd` |

`scripts/dev-token.sh` ejecuta el mismo flujo Authorization Code + PKCE del frontend con curl, así que el client no necesita `USER_PASSWORD_AUTH` (solo SRP + refresh, como en `terraform/auth.tf`). Los tokens duran 1 hora.

## Frontend

El frontend lee su configuración de `UniFlow-Frontend/.env.local` (ignorado por git, tiene prioridad sobre `.env`). Ya se creó con:

```
# Cada servicio tiene UNA URL base completa; el código solo añade rutas de recurso (/periods, /courses, ...).
# Directo a los servicios (sin gateway, sin prefijo ni versión):
VITE_ACADEMIC_SERVICE_URL=http://localhost:3001
VITE_NOTIFICATIONS_SERVICE_URL=http://localhost:3003
# A través del API Gateway de Floci (prefijo y versión incluidos en la URL):
# VITE_ACADEMIC_SERVICE_URL=http://uniflow.execute-api.localhost.floci.io:4566/api/academic/v2
# VITE_NOTIFICATIONS_SERVICE_URL=http://uniflow.execute-api.localhost.floci.io:4566/api/notifications/v2
VITE_COGNITO_DOMAIN=http://localhost.floci.io:4566/cognito-idp
VITE_COGNITO_CLIENT_ID=uniflow-spa
# más VITE_APIM_TOKEN / VITE_GOOGLE_* / VITE_NOTIFICATIONS_WEB_APP_URL
# con valores de relleno: src/env.ts los exige pero no se usan en local
```

```bash
cd UniFlow-Frontend
pnpm install            # si hace falta
pnpm dev                # vite --port 3000
```

Abre <http://localhost:3000>, pulsa el login con Cognito, entra con `user-a@uniflow.local` en el Hosted UI de Floci y vuelve a `/auth/callback`. El puerto 3000 y el callback `http://localhost:3000/auth/callback` están registrados en el client; para otro origen usa `FRONTEND_ORIGIN=http://localhost:5173 docker compose ... up -d` (CORS y callback se derivan de esa variable).

El frontend llama a `<base>/academic/v2/...` y `<base>/notifications/v2/...`; el gateway recorta el prefijo, así que academic recibe `/periods` y notification `/user/{id}`. El frontend ya usa el contrato de academic (`courses`, tareas servidas por academic en `/tasks`), así que funciona de extremo a extremo contra este stack.

## El issuer y por qué funciona desde el host y desde Docker

Cognito de Floci firma tokens con `iss = FLOCI_BASE_URL/<poolId>` = `http://localhost.floci.io:4566/us-east-1_UniflowDev`. `localhost.floci.io` es un nombre DNS público que resuelve a `127.0.0.1`: en el host llega al puerto publicado de Floci. En la red `uniflow-dev` el servicio `floci` tiene ese mismo nombre como alias de red, de modo que academic y la Lambda (que Floci conecta a la misma red con `FLOCI_SERVICES_DOCKER_NETWORK`) descargan el JWKS de la misma URL. Pool id y client id están fijados con las etiquetas `floci:override-id` y `floci:override-cognito-client-id=use-name` (client id = `uniflow-spa`), y el id del API también (`uniflow`), por lo que todas las URLs son estables. Hace falta resolución DNS pública de `*.localhost.floci.io`; si no, añade esos nombres a `/etc/hosts`.

## Rutas del gateway

Base: `http://uniflow.execute-api.localhost.floci.io:4566` (stage `$default`).

| Ruta | Auth | Destino |
|---|---|---|
| `GET /api/academic/health` | pública | `academic:3001/health` |
| `ANY /api/academic/v2/{proxy+}` | Lambda authorizer | `academic:3001/{proxy}` |
| `ANY /api/notifications/v2/{proxy+}` | Lambda authorizer | `notification:3003/{proxy}` |
| `OPTIONS` (cualquiera) | no (preflight lo responde el gateway) | - |

Las rutas son las de producción (`ANY /api/{proxy+}`) más un prefijo por servicio. El header `Authorization` se reenvía intacto. Sin header el gateway responde 401; con token inválido o expirado, el authorizer responde 403.

El authorizer (`lambdas/http_authorizer`, Node 22, solo `node:crypto` y `fetch`) valida: firma RS256 contra el JWKS (cacheado en memoria), `iss`, `exp`/`nbf`, `token_use == access` y `client_id` dentro de `COGNITO_ALLOWED_CLIENT_IDS`. Tests: `cd lambdas/http_authorizer && node --test test/`.

## Diferencias con producción

- Producción: HTTP API con authorizer JWT nativo de Cognito -> VPC Link -> ALB interno -> ECS. Local: Lambda authorizer (pedido para este entorno) y proxy HTTP directo a los contenedores, sin VPC Link ni ALB.
- El issuer es `http://localhost.floci.io:4566/...` en vez de `https://cognito-idp.<region>.amazonaws.com/...`; el Hosted UI de Floci es una página mínima, no la de Cognito, y su dominio vive bajo `/cognito-idp` (el prefijo `uniflow-dev` del dominio no se usa en la URL).
- Floci no es AWS: solo emula lo que se probó aquí (ver límites).
- Docker socket: Floci monta `/var/run/docker.sock`, equivalente a root en el host. No expongas este stack fuera de tu máquina.

## Límites conocidos de Floci 2.3.0 y lo que está a medias

- Floci no expone el contexto del Lambda authorizer en el mapeo de parámetros del integration (`$context.authorizer.sub` queda vacío), así que el gateway no añade `X-User-Id`. Academic no lo necesita (revalida el JWT) y notification solo lo registra en un log; su `userId` va en la ruta y notification no comprueba que coincida con el token (comportamiento preexistente del servicio).
- Con rutas solapadas (`/x/v2/{proxy+}` y `/x/{proxy+}`) Floci no elige la más específica, por eso solo existen las rutas con `v2`.
- Las respuestas de error del propio gateway (401 sin token, 403 del authorizer) no llevan `Access-Control-Allow-Origin`: el navegador las verá como error de red/CORS, no como 401 (el interceptor del frontend no se dispara). Las respuestas de los servicios sí llevan CORS (lo añaden ellos); el preflight lo responde el gateway.
- El endpoint de token de Cognito solo responde preflight para los orígenes de `FLOCI_SECURITY_EXTRA_CORS_ALLOWED_ORIGINS` (se fija a `FRONTEND_ORIGIN`).
- El `sub` de los usuarios no se puede fijar: cambia cada vez que Floci arranca de cero. Los datos de postgres/mongo persisten en volúmenes, así que tras `down` sin `-v` los datos viejos quedan asociados a un `sub` que ya no existe. Usa `down -v`.
- El estado de Floci es efímero: si reinicias solo el contenedor `floci`, vuelve a ejecutar `docker compose -f docker-compose.dev.yml run --rm floci-init`.
- Notification: sin SES ni push, sin WebSocket (el frontend apunta `VITE_NOTIFICATIONS_WEB_APP_URL` a un puerto cerrado). Su Dockerfile real falla con pnpm actual ("Ignored build scripts") y su repo no tiene `.dockerignore` (copiaría el `.env` real a la imagen), por lo que se usa `docker/notification/Dockerfile` + `Dockerfile.dockerignore`, con el mismo build pero copiando `pnpm-workspace.yaml` y `.npmrc` antes del install.
- Token expirado: cubierto solo por tests unitarios del validador, no se esperó a una expiración real.

## Convivencia con el stack de `uniflow-academic-service`

`uniflow-academic-service/docker-compose.dev.yml` sigue funcionando por separado, pero también publica el puerto `4566` (y `3001`/`7001-7010`): no pueden correr a la vez. Para cambiar de uno a otro, `docker compose ... stop` del que esté activo.

Ese compose tambien deja el client `uniflow-spa` listo para el login del frontend (Hosted UI, `code`, callback `http://localhost:3000/auth/callback`) y actualiza el client si ya existia en el estado persistente de Floci. Detalles y como resetear el estado: `uniflow-academic-service/README.md`.
