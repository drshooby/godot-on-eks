package com.fps.auth

import com.auth0.jwt.JWT
import com.auth0.jwt.algorithms.Algorithm
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.mindrot.jbcrypt.BCrypt
import java.util.UUID

fun main() {
    val port = envInt("PORT", 8080)
    embeddedServer(Netty, port = port, module = Application::module).start(wait = true)
}

private fun env(name: String, default: String? = null): String =
    System.getenv(name) ?: default ?: error("missing env $name")

private fun envInt(name: String, default: Int): Int =
    System.getenv(name)?.toIntOrNull() ?: default

private val json = Json { ignoreUnknownKeys = true; prettyPrint = false }

fun Application.module() {
    val dataSource = createDataSource()
    val jwtSecret = env("JWT_SECRET")
    val algorithm = Algorithm.HMAC256(jwtSecret)

    install(ContentNegotiation) {
        json(json)
    }
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            call.respond(
                HttpStatusCode.InternalServerError,
                ErrorBody("internal_error", cause.message ?: "error"),
            )
        }
    }

    routing {
        get("/health") { call.respond(mapOf("status" to "ok")) }

        get("/ready") {
            dataSource.connection.use { c ->
                c.prepareStatement("SELECT 1").executeQuery().use { rs ->
                    if (rs.next()) call.respond(mapOf("status" to "ready"))
                    else call.respond(HttpStatusCode.ServiceUnavailable, mapOf("status" to "not_ready"))
                }
            }
        }

        post("/register") {
            val body = call.receive<RegisterReq>()
            if (body.email.isBlank() || body.password.length < 8) {
                call.respond(HttpStatusCode.BadRequest, ErrorBody("validation_error", "email and password (8+ chars) required"))
                return@post
            }
            val playerId = UUID.randomUUID().toString()
            val hash = BCrypt.hashpw(body.password, BCrypt.gensalt())
            try {
                dataSource.connection.use { c ->
                    c.prepareStatement(
                        "INSERT INTO players (id, email, password_hash) VALUES (?, ?, ?)",
                    ).use { ps ->
                        ps.setString(1, playerId)
                        ps.setString(2, body.email.trim())
                        ps.setString(3, hash)
                        ps.executeUpdate()
                    }
                }
            } catch (e: Exception) {
                if (e.message?.contains("Duplicate", ignoreCase = true) == true) {
                    call.respond(HttpStatusCode.Conflict, ErrorBody("email_exists", "email already registered"))
                    return@post
                }
                throw e
            }
            val token = mintToken(algorithm, playerId)
            call.respond(RegisterRes(token = token, player_id = playerId))
        }

        post("/login") {
            val body = call.receive<LoginReq>()
            val row = dataSource.connection.use { c ->
                c.prepareStatement("SELECT id, password_hash FROM players WHERE email = ?").use { ps ->
                    ps.setString(1, body.email.trim())
                    ps.executeQuery().use { rs ->
                        if (!rs.next()) null else Pair(rs.getString("id"), rs.getString("password_hash"))
                    }
                }
            }
            if (row == null || !BCrypt.checkpw(body.password, row.second)) {
                call.respond(HttpStatusCode.Unauthorized, ErrorBody("invalid_credentials", "bad email or password"))
                return@post
            }
            val token = mintToken(algorithm, row.first)
            call.respond(LoginRes(token = token, player_id = row.first))
        }

        post("/validate") {
            val body = call.receive<ValidateReq>()
            try {
                val verifier = JWT.require(algorithm).build()
                val decoded = verifier.verify(body.token)
                val sub = decoded.subject ?: decoded.getClaim("player_id").asString()
                ?: return@post call.respond(HttpStatusCode.Unauthorized, ErrorBody("invalid_token", "missing subject"))
                call.respond(ValidateRes(valid = true, player_id = sub))
            } catch (_: Exception) {
                call.respond(HttpStatusCode.Unauthorized, ErrorBody("invalid_token", "token rejected"))
            }
        }
    }
}

private fun mintToken(algorithm: Algorithm, playerId: String): String =
    JWT.create()
        .withSubject(playerId)
        .withClaim("player_id", playerId)
        .sign(algorithm)

private fun createDataSource(): HikariDataSource {
    val host = env("DATABASE_HOST", "localhost")
    val port = env("DATABASE_PORT", "3306")
    val name = env("DATABASE_NAME", "fps")
    val user = env("DATABASE_USER")
    val pass = env("DATABASE_PASSWORD")
    val cfg = HikariConfig().apply {
        jdbcUrl = "jdbc:mysql://$host:$port/$name?useSSL=false&allowPublicKeyRetrieval=true"
        username = user
        password = pass
        maximumPoolSize = 10
    }
    return HikariDataSource(cfg)
}

@Serializable
private data class RegisterReq(val email: String, val password: String)

@Serializable
private data class RegisterRes(val token: String, val player_id: String)

@Serializable
private data class LoginReq(val email: String, val password: String)

@Serializable
private data class LoginRes(val token: String, val player_id: String)

@Serializable
private data class ValidateReq(val token: String)

@Serializable
private data class ValidateRes(val valid: Boolean, val player_id: String)

@Serializable
private data class ErrorBody(val error: String, val message: String)
