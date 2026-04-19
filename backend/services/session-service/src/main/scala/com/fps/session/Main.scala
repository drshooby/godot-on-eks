package com.fps.session

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import com.google.gson.{Gson, JsonArray, JsonNull, JsonObject}
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import spark.{Request, Response, Spark}

import java.sql.Timestamp
import java.time.Instant
import java.util.UUID
import scala.util.Using

object Main:

  def main(args: Array[String]): Unit =
    val port = Option(System.getenv("PORT")).flatMap(_.toIntOption).getOrElse(8080)
    Spark.port(port)

    val corsOrigins =
      Option(System.getenv("CORS_ALLOWED_ORIGINS")).getOrElse(
        "http://localhost:8090,http://127.0.0.1:8090",
      ).split(',').map(_.trim).filter(_.nonEmpty).toSeq

    def applyCors(req: Request, res: Response): Unit =
      Option(req.headers("Origin")) match
        case Some(origin) if corsOrigins.contains(origin) =>
          res.header("Access-Control-Allow-Origin", origin)
          res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
          res.header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        case _ => ()

    Spark.before((req: Request, res: Response) => applyCors(req, res))

    Spark.options(
      "/*",
      (req: Request, res: Response) => {
        applyCors(req, res)
        res.status(204)
        ""
      },
    )

    val ds = createDs()
    val secret = Option(System.getenv("JWT_SECRET")).getOrElse:
      throw IllegalStateException("JWT_SECRET required")
    val algo = Algorithm.HMAC256(secret)

    Spark.get(
      "/health",
      (_: Request, res: Response) => {
        res.`type`("application/json")
        """{"status":"ok"}"""
      },
    )

    Spark.get(
      "/ready",
      (_: Request, res: Response) => {
        res.`type`("application/json")
        try
          Using.resource(ds.getConnection) { c =>
            Using.resource(c.prepareStatement("SELECT 1")) { ps =>
              Using.resource(ps.executeQuery())(_.next())
            }
          }
          """{"status":"ready"}"""
        catch
          case e: Exception =>
            res.status(503)
            val jo = JsonObject()
            jo.addProperty("status", "not_ready")
            jo.addProperty("message", Option(e.getMessage).getOrElse("error"))
            jo.toString
      },
    )

    Spark.post(
      "/session/start",
      (req: Request, res: Response) => {
        res.`type`("application/json")
        val playerId = parseBearer(req, algo)
        val sid = UUID.randomUUID().toString
        Using.resource(ds.getConnection) { c =>
          Using.resource(
            c.prepareStatement("INSERT INTO game_sessions (id, player_id) VALUES (?, ?)"),
          ) { ps =>
            ps.setString(1, sid)
            if playerId == null then ps.setNull(2, java.sql.Types.CHAR)
            else ps.setString(2, playerId)
            ps.executeUpdate()
          }
        }
        val jo = JsonObject()
        jo.addProperty("session_id", sid)
        jo.toString
      },
    )

    Spark.post(
      "/session/end",
      (req: Request, res: Response) => {
        res.`type`("application/json")
        val m = new Gson().fromJson(req.body(), classOf[java.util.Map[String, AnyRef]])
        val sid = Option(m.get("session_id")).map(_.toString).orNull
        val scoreN = Option(m.get("score")).collect { case n: Number => n.intValue() }
        val wavesN = Option(m.get("waves")).collect { case n: Number => n.intValue() }
        val killsN = Option(m.get("kills")).collect { case n: Number => n.intValue() }
        if sid == null || scoreN.isEmpty || wavesN.isEmpty || killsN.isEmpty then
          res.status(400)
          val jo = JsonObject()
          jo.addProperty("error", "validation_error")
          jo.addProperty("message", "session_id, score, waves, kills required")
          jo.toString
        else
          val updated = Using.resource(ds.getConnection) { c =>
            Using.resource(
              c.prepareStatement(
                """UPDATE game_sessions SET ended_at = ?, score = ?, waves = ?, kills = ?
                  |WHERE id = ? AND ended_at IS NULL""".stripMargin,
              ),
            ) { ps =>
              ps.setTimestamp(1, Timestamp.from(Instant.now()))
              ps.setInt(2, scoreN.get)
              ps.setInt(3, wavesN.get)
              ps.setInt(4, killsN.get)
              ps.setString(5, sid)
              ps.executeUpdate()
            }
          }
          if updated == 0 then
            res.status(404)
            val jo = JsonObject()
            jo.addProperty("error", "not_found")
            jo.addProperty("message", "session not found or already ended")
            jo.toString
          else
            val jo = JsonObject()
            jo.addProperty("ok", true)
            jo.toString
      },
    )

    Spark.get(
      "/session/history/:player",
      (req: Request, res: Response) => {
        res.`type`("application/json")
        val pid = req.params("player")
        val buf = scala.collection.mutable.ArrayBuffer[Map[String, AnyRef]]()
        Using.resource(ds.getConnection) { c =>
          Using.resource(
            c.prepareStatement(
              """SELECT id, started_at, ended_at, score, waves, kills FROM game_sessions
                |WHERE player_id = ? ORDER BY started_at DESC""".stripMargin,
            ),
          ) { ps =>
            ps.setString(1, pid)
            Using.resource(ps.executeQuery()) { rs =>
              while rs.next() do
                buf += Map(
                  "session_id" -> rs.getString("id"),
                  "started_at" -> (Option(rs.getTimestamp("started_at")).map(_.toInstant.toString).orNull: AnyRef),
                  "ended_at" -> (Option(rs.getTimestamp("ended_at")).map(_.toInstant.toString).orNull: AnyRef),
                  "score" -> (if rs.getObject("score") == null then null else Integer.valueOf(rs.getInt("score"))),
                  "waves" -> (if rs.getObject("waves") == null then null else Integer.valueOf(rs.getInt("waves"))),
                  "kills" -> (if rs.getObject("kills") == null then null else Integer.valueOf(rs.getInt("kills"))),
                )
            }
          }
        }
        val arr = JsonArray()
        buf.foreach { row =>
          val o = JsonObject()
          row.foreach { case (k, v) =>
            v match
              case null          => o.add(k, JsonNull.INSTANCE)
              case s: String     => o.addProperty(k, s)
              case i: Integer    => o.addProperty(k, i)
              case other: AnyRef => o.addProperty(k, other.toString)
          }
          arr.add(o)
        }
        val top = JsonObject()
        top.add("sessions", arr)
        top.toString
      },
    )

    println(s"session-service listening on $port")
  end main

  private def parseBearer(req: Request, algorithm: Algorithm): String | Null =
    val auth = req.headers("Authorization")
    if auth == null || !auth.startsWith("Bearer ") then return null
    val token = auth.substring("Bearer ".length).trim
    try
      val jwt = JWT.require(algorithm).build().verify(token)
      Option(jwt.getSubject).orElse(Option(jwt.getClaim("player_id").asString())).orNull
    catch case _: Exception => null

  private def createDs(): HikariDataSource =
    val host = Option(System.getenv("DATABASE_HOST")).getOrElse("localhost")
    val port = Option(System.getenv("DATABASE_PORT")).getOrElse("3306")
    val name = Option(System.getenv("DATABASE_NAME")).getOrElse("fps")
    val cfg = new HikariConfig()
    cfg.setJdbcUrl(s"jdbc:mysql://$host:$port/$name?useSSL=false&allowPublicKeyRetrieval=true")
    cfg.setUsername(System.getenv("DATABASE_USER"))
    cfg.setPassword(System.getenv("DATABASE_PASSWORD"))
    cfg.setMaximumPoolSize(10)
    HikariDataSource(cfg)

end Main
