"""Carga las 5 fuentes de RutaTaller a staging en SQL Server y ejecuta la transformación.

Requisitos previos: haber corrido sql/01_crear_tablas.sql, 02_transformar.sql y 03_reglas.sql.
Uso:  pip install -r etl/requirements.txt
      python etl/cargar.py            (lee credenciales de .env en la raíz del proyecto)

Los datos se cargan como texto, tal cual vienen; la limpieza ocurre en SQL (etl.usp_transformar)
para que quede documentada y reproducible en la base.
"""
import csv
import json
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pymssql

RAIZ = Path(__file__).resolve().parent.parent


def leer_env(ruta: Path) -> None:
    if not ruta.exists():
        sys.exit(f"No existe {ruta}. Copie .env.example a .env y complete las credenciales.")
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            k, v = linea.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def leer_csv(nombre: str, sep: str = ",") -> list[tuple]:
    with open(RAIZ / nombre, encoding="utf-8-sig", newline="") as f:
        filas = list(csv.reader(f, delimiter=sep))
    return [tuple(r) for r in filas[1:] if r]  # sin encabezado ni líneas vacías


def leer_fuentes() -> dict[str, list[tuple]]:
    centros = json.loads((RAIZ / "Centros.json").read_text(encoding="utf-8-sig"))
    familias = ET.parse(RAIZ / "Familias.xml").getroot()
    return {
        "stg.Eventos": leer_csv("Eventos.csv"),
        "stg.Centros": [(c["Centro_ID"], c["Centro"]) for c in centros],
        "stg.Familias": [(f.get("Familia_ID"), f.get("Nombre")) for f in familias.iter("Familia")],
        "stg.Calendario": leer_csv("Calendario.txt", sep="|"),
        "stg.Capacidad": leer_csv("Capacidad.csv"),
    }


def imprimir(cur, titulo: str) -> None:
    print(f"\n== {titulo} ==")
    cols = [c[0] for c in cur.description]
    print(" | ".join(cols))
    for fila in cur.fetchall():
        print(" | ".join("" if v is None else str(v) for v in fila))


def main() -> None:
    leer_env(RAIZ / ".env")
    fuentes = leer_fuentes()

    print(f"Conectando a {os.environ['DB_SERVER']}:{os.environ.get('DB_PORT', '1433')} ...", flush=True)
    conn = pymssql.connect(
        server=os.environ["DB_SERVER"],
        port=os.environ.get("DB_PORT", "1433"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ.get("DB_NAME", "ajomuch92_ruta_taller"),
        charset="UTF-8",
        login_timeout=15,  # sin esto, un servidor inalcanzable cuelga el script
        timeout=600,
    )
    print("Conectado.", flush=True)
    try:
        cur = conn.cursor()
        for tabla, filas in fuentes.items():
            ancho = len(filas[0])
            if any(len(f) != ancho for f in filas):
                sys.exit(f"{tabla}: hay filas con distinto número de columnas, revisar el archivo.")
            cur.execute(f"TRUNCATE TABLE {tabla}")
            fila = "(" + ", ".join(["%s"] * ancho) + ")"
            # 1000 filas por INSERT (máximo de SQL Server); executemany va fila por fila y es muy lento en red
            for i in range(0, len(filas), 1000):
                lote = filas[i:i + 1000]
                cur.execute(f"INSERT INTO {tabla} VALUES " + ", ".join([fila] * len(lote)),
                            tuple(v for f in lote for v in f))
                print(f"  {tabla}: {i + len(lote)}/{len(filas)}", flush=True)
        conn.commit()

        print("Ejecutando etl.usp_transformar ...", flush=True)
        cur.execute("EXEC etl.usp_transformar")
        imprimir(cur, "Controles de carga")
        conn.commit()

        print("Ejecutando dw.usp_simular_reglas ...", flush=True)
        cur.execute("EXEC dw.usp_simular_reglas")
        conn.commit()
        cur.execute("SELECT * FROM dw.vResumenRegla ORDER BY Periodo, Escenario, Regla")
        imprimir(cur, "Resumen de reglas")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
