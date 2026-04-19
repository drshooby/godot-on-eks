package com.fps.score

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import spark.Request
import spark.Spark

class Main {
    static void main(String[] args) {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"))
        Spark.port(port)

        def ds = createDs()
        def secret = System.getenv("JWT_SECRET")
        if (!secret) throw new IllegalStateException("JWT_SECRET required")
        def algo = Algorithm.HMAC256(secret)

        Spark.get("/health") { _, res ->
            res.type("application/json")
            JsonOutput.toJson([status: "ok"])
        }

        Spark.get("/ready") { _, res ->
            res.type("application/json")
            try {
                ds.connection.withCloseable { c ->
                    c.prepareStatement("SELECT 1").withCloseable { ps ->
                        ps.executeQuery().withCloseable { rs ->
                            rs.next()
                        }
                    }
                }
                JsonOutput.toJson([status: "ready"])
            } catch (Exception e) {
                res.status(503)
                JsonOutput.toJson([status: "not_ready", message: e.message])
            }
        }

        Spark.get("/leaderboard") { _, res ->
            res.type("application/json")
            def rows = []
            ds.connection.withCloseable { c ->
                c.prepareStatement('''SELECT p.email, s.score, s.wave_reached, s.created_at
                    FROM scores s JOIN players p ON p.id = s.player_id
                    ORDER BY s.score DESC LIMIT 10''').withCloseable { ps ->
                    ps.executeQuery().withCloseable { rs ->
                        while (rs.next()) {
                            rows << [
                                    email       : rs.getString("email"),
                                    score       : rs.getInt("score"),
                                    wave_reached: rs.getInt("wave_reached"),
                                    created_at  : rs.getTimestamp("created_at").toInstant().toString(),
                            ]
                        }
                    }
                }
            }
            JsonOutput.toJson([entries: rows])
        }

        Spark.get("/scores/:player") { Request req, res ->
            res.type("application/json")
            def pid = req.params("player")
            def row = null
            ds.connection.withCloseable { c ->
                c.prepareStatement(
                        '''SELECT MAX(score) AS best_score FROM scores WHERE player_id = ?''',
                ).withCloseable { ps ->
                    ps.setString(1, pid)
                    ps.executeQuery().withCloseable { rs ->
                        if (rs.next()) {
                            def best = rs.getObject("best_score")
                            row = [player_id: pid, best_score: best == null ? null : best as int]
                        }
                    }
                }
            }
            if (row == null) {
                res.status(404)
                return JsonOutput.toJson([error: "not_found", message: "no scores for player"])
            }
            JsonOutput.toJson(row)
        }

        Spark.post("/scores") { Request req, res ->
            res.type("application/json")
            def auth = req.headers("Authorization")
            if (auth == null || !auth.startsWith("Bearer ")) {
                res.status(401)
                return JsonOutput.toJson([error: "unauthorized", message: "Bearer token required"])
            }
            def token = auth.substring("Bearer ".length()).trim()
            String playerId
            try {
                def jwt = JWT.require(algo).build().verify(token)
                playerId = jwt.subject ?: jwt.getClaim("player_id").asString()
            } catch (ignored) {
                res.status(401)
                return JsonOutput.toJson([error: "invalid_token", message: "bad jwt"])
            }

            def body = new JsonSlurper().parseText(req.body()) as Map
            def score = (body.score as Number)?.intValue()
            def wave = (body.wave_reached as Number)?.intValue()
            if (score == null || wave == null) {
                res.status(400)
                return JsonOutput.toJson([error: "validation_error", message: "score and wave_reached required"])
            }

            ds.connection.withCloseable { c ->
                c.prepareStatement(
                        'INSERT INTO scores (player_id, score, wave_reached) VALUES (?,?,?)',
                ).withCloseable { ps ->
                    ps.setString(1, playerId)
                    ps.setInt(2, score)
                    ps.setInt(3, wave)
                    ps.executeUpdate()
                }
            }
            JsonOutput.toJson([ok: true])
        }

        println "score-service listening on ${port}"
    }

    static HikariDataSource createDs() {
        def host = System.getenv().getOrDefault("DATABASE_HOST", "localhost")
        def port = System.getenv().getOrDefault("DATABASE_PORT", "3306")
        def name = System.getenv().getOrDefault("DATABASE_NAME", "fps")
        def cfg = new HikariConfig(
                jdbcUrl: "jdbc:mysql://${host}:${port}/${name}?useSSL=false&allowPublicKeyRetrieval=true",
                username: System.getenv("DATABASE_USER"),
                password: System.getenv("DATABASE_PASSWORD"),
                maximumPoolSize: 10,
        )
        new HikariDataSource(cfg)
    }
}
