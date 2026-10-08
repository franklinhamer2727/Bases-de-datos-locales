// Crea el usuario de la aplicacion con permisos SOLO sobre su base.
// La imagen oficial ejecuta /docker-entrypoint-initdb.d/*.js con mongosh,
// autenticado como root, SOLO en el primer arranque (volumen vacio).
// No se usa root desde Airflow/ETL.
const appDb = process.env.APP_DB;
const appUser = process.env.APP_USER;
const appPassword = process.env.APP_PASSWORD;

if (!appDb || !appUser || !appPassword) {
  throw new Error("[init] faltan APP_DB / APP_USER / APP_PASSWORD");
}

const target = db.getSiblingDB(appDb);

if (target.getUser(appUser) === null) {
  target.createUser({
    user: appUser,
    pwd: appPassword,
    roles: [
      { role: "readWrite", db: appDb },
      { role: "dbAdmin", db: appDb }      // indices, stats, validadores
    ]
  });
  print(`[init] usuario '${appUser}' creado en '${appDb}'`);
} else {
  print(`[init] usuario '${appUser}' ya existe`);
}

// Una base vacia no "existe" en Mongo hasta tener datos: se deja un registro.
target.getCollection("_init_log").updateOne(
  { _id: "01_usuario_app" },
  { $set: { applied_at: new Date() } },
  { upsert: true }
);
