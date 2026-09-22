# claude-bulk-reader

Enruta las lecturas de archivos grandes de Claude Code hacia un subagente barato,
para que el contexto principal no se llene de código que solo querías consultar.

Inspirado en el [shunt de Spotify](https://wavect.io/es/blog/spotify-shunt-claude-code-token-routing/),
que delega lecturas masivas a modelos auxiliares vía Portal. Ese plugin depende de
infraestructura interna de Spotify (Portal + AiKA) y no es instalable fuera.
Esto reimplementa el patrón con piezas que Claude Code ya trae: un subagente en
Haiku y dos hooks `PreToolUse`.

## Qué hace

1. **`bulk-reader`** — subagente en Haiku, solo lectura. Recibe una pregunta
   concreta, lee lo que haga falta y devuelve un extracto con referencias
   `ruta:línea`. Nunca vuelca el archivo.
2. **Dos hooks** que bloquean el volcado íntegro de archivos por encima de un
   umbral (350 líneas por defecto) y redirigen a ese subagente:
   - `shunt-file-size.sh` sobre la tool `Read`
   - `shunt-bash-read.sh` sobre `Bash` (`cat`, `head`, `tail`, `sed -n`, `nl`, `bat`)

El segundo importa más de lo que parece: en modo auto, Claude Code suele leer con
`cat` y `sed -n`, que nunca pasan por la tool `Read`. Cubrir solo `Read` deja el
shunt casi inactivo.

## Qué NO bloquea

El criterio es conservador: solo se bloquea el volcado íntegro al contexto.
Pasan sin tocar las lecturas que ya vienen acotadas o filtradas:

| Caso | Por qué pasa |
|---|---|
| `Read` con `offset`/`limit` | Lectura dirigida, la vía correcta para editar |
| `head -50`, `sed -n '10,60p'` | Ya está acotado por debajo del umbral |
| `cat big.java \| grep foo` | El pipe reduce la salida |
| `cat big.java > out.txt` | Redirección: no llega al contexto |
| `cat > f <<EOF` | Heredoc: es escritura |
| `grep`, `rg`, `wc` | No vuelcan el archivo |

## Instalación

Requiere `jq`.

```bash
git clone https://github.com/cgonzalez-civitatis/claude-bulk-reader.git
cd claude-bulk-reader
./install.sh
```

El instalador copia los hooks a `~/.claude/scripts/`, el subagente a
`~/.claude/agents/`, y añade los dos matchers a `~/.claude/settings.json`
(con backup previo en `~/.claude/backups/`). Es idempotente.

**Último paso, manual y necesario:** copia `CLAUDE.md.example` en tu
`~/.claude/CLAUDE.md`. Los hooks son un backstop reactivo — solo hablan cuando
ya has fallado. Ese bloque es lo que hace que Claude delegue *antes* de chocar,
y lo que le dice cuándo **no** delegar (editar, arquitectura, seguridad).

Desinstalar: `./install.sh --uninstall`

## Ajustes

| Variable | Efecto |
|---|---|
| `SHUNT_MIN_LINES=600` | Sube el umbral (por defecto 350) |
| `SHUNT_OFF=1` | Desactiva ambos hooks en la sesión |

Quedan siempre exentas las rutas `CLAUDE.md`, `MEMORY.md`, `.claude/` y `.env`,
además de binarios e imágenes.

## Verificar

```bash
./test/test-hooks.sh              # contra los scripts del repo
./test/test-hooks.sh --installed  # contra los ya instalados
```

25 casos, incluidos heredocs, pipes, redirecciones y comandos encadenados.

## ¿Cuánto ahorra?

Medido sobre una clase de test Java real de 791 líneas (~10.400 tokens),
preguntando por sus mocks, escenarios y excepciones:

| | Contexto principal | Coste |
|---|---|---|
| Leer el archivo entero (Opus 5) | ~10.400 tokens | $0,052 |
| Delegar en `bulk-reader` (Haiku 4.5) | ~713 tokens | $0,035 |

**−94% de contexto y ~32% más barato ya en la primera consulta.** El extracto fue
fiel: 17 de 17 métodos `@Test`, referencias `ruta:línea` correctas.

La distancia crece por turno, porque el contexto se reenvía en cada petición:

| Turnos después | Leer entero | Delegar |
|---|---|---|
| 5 | $0,31 | $0,05 |
| 10 | $0,57 | $0,07 |
| 20 | $1,09 | $0,10 |

Precios oficiales a fecha de medición: Opus 5 $5/$25 por MTok, Haiku 4.5 $1/$5.
Nota: el artículo original advierte que el ahorro declarado mide contexto y no la
factura conjunta. Es cierto en el montaje de Spotify, que paga un modelo externo
por encima; aquí no hay ese salto — mismo proveedor y un modelo 5× más barato.

## Límites conocidos

- El hook de `Bash` hace word-splitting sin comillas: **una ruta con espacios no
  se detecta** y pasa sin bloquear.
- No cubre lecturas por MCP ni por herramientas de terceros.
- El subagente no edita. Para modificar código, lee el fragmento tú.

## Licencia

MIT
