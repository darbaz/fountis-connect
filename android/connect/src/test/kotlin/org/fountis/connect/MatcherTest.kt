package org.fountis.connect

import java.util.Calendar
import java.util.GregorianCalendar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MatcherTest {
    private val year = GregorianCalendar().get(Calendar.YEAR)

    private val offerJson = """
        {"app":{"name":"Acme"},"config":{"max_notifications_per_day":1,"quiet_hours":[22,9],"check_interval_minutes":240},
         "surveys":[{"offer_id":"of_1","conditions":{"all":[
            {"attr":"gender","op":"in","value":["female"]},
            {"attr":"age","op":"between","value":[25,44]},
            {"attr":"city","op":"in","value":["erbil"]}]},
          "required_attrs":["gender","birth_year"],"loi_minutes":5,"reward":{"mode":"free"},"expires_at":"2099-01-01T00:00:00.000Z"}]}
    """.trimIndent()

    private fun offer(): Offer = parseSurveys(offerJson).surveys.single()

    private fun info(gender: String, birthYear: Int, city: String = "erbil") =
        TokenInfo("sub", mapOf("gender" to gender, "birth_year" to birthYear, "city" to city), null)

    @Test
    fun matchesWhenEveryConditionHolds() {
        assertTrue(Matcher.matches(offer(), info("female", year - 33)))
    }

    @Test
    fun rejectsWrongGenderAgeOrCity() {
        assertFalse(Matcher.matches(offer(), info("male", year - 33)))
        assertFalse(Matcher.matches(offer(), info("female", year - 50)))
        assertFalse(Matcher.matches(offer(), info("female", year - 33, city = "duhok")))
    }

    @Test
    fun missingRequiredAttributeDoesNotMatch() {
        assertFalse(Matcher.matches(offer(), TokenInfo("sub", mapOf("gender" to "female"), null)))
    }

    @Test
    fun ageBoundsAreInclusive() {
        val c = Condition("age", "between", listOf(25.0, 44.0))
        assertTrue(Matcher.holds(c, mapOf("birth_year" to year - 25), System.currentTimeMillis()))
        assertTrue(Matcher.holds(c, mapOf("birth_year" to year - 44), System.currentTimeMillis()))
        assertFalse(Matcher.holds(c, mapOf("birth_year" to year - 45), System.currentTimeMillis()))
    }

    @Test
    fun otherOperators() {
        val now = System.currentTimeMillis()
        assertTrue(Matcher.holds(Condition("city", "not_in", listOf("duhok")), mapOf("city" to "erbil"), now))
        assertFalse(Matcher.holds(Condition("city", "not_in", listOf("erbil")), mapOf("city" to "erbil"), now))
        assertTrue(Matcher.holds(Condition("lang", "eq", "ku"), mapOf("lang" to "ku"), now))
        assertTrue(Matcher.holds(Condition("age", "gte", 18.0), mapOf("birth_year" to year - 18), now))
        assertTrue(Matcher.holds(Condition("age", "lte", 18.0), mapOf("birth_year" to year - 18), now))
        assertFalse(Matcher.holds(Condition("age", "gte", 18.0), mapOf("city" to "erbil"), now)) // no birth_year
    }

    @Test
    fun expiredOfferDoesNotMatch() {
        val expired = Offer("of_2", emptyList(), emptyList(), null, null, "2001-01-01T00:00:00Z")
        assertFalse(Matcher.matches(expired, info("female", year - 33)))
        assertTrue(Matcher.matches(Offer("of_3", emptyList(), emptyList(), null, null, null), info("female", year - 33)))
    }

    @Test
    fun guestsOnlyMatchGuestOffers() {
        val guestOffer = Offer("of_g", emptyList(), emptyList(), null, null, null, guest = true)
        val plainOffer = Offer("of_p", emptyList(), emptyList(), null, null, null)
        assertTrue(Matcher.matchesGuest(guestOffer))
        assertFalse(Matcher.matchesGuest(plainOffer))
        assertFalse(Matcher.matchesGuest(Offer("of_e", emptyList(), emptyList(), null, null, "2001-01-01T00:00:00Z", guest = true)))
    }

    @Test
    fun parsesGuestFlags() {
        val r = parseSurveys("""{"app":{"name":"P","guests":true},"surveys":[{"offer_id":"of_a","guest":true,"reward":{"mode":"free"}},{"offer_id":"of_b","reward":{"mode":"free"}}]}""")
        assertTrue(r.guests)
        assertTrue(r.surveys[0].guest)
        assertFalse(r.surveys[1].guest)
    }

    @Test
    fun parsesDatesWithOffsets() {
        assertEquals(0L, Matcher.parseDate("1970-01-01T00:00:00Z"))
        assertEquals(0L, Matcher.parseDate("1970-01-01T02:00:00.000+02:00"))
        assertNull(Matcher.parseDate("not a date"))
    }

    @Test
    fun quietHoursWrapMidnight() {
        fun at(hour: Int): Long = GregorianCalendar().apply { set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, 0) }.timeInMillis
        assertTrue(Matcher.inQuietHours(listOf(22, 9), at(23)))
        assertTrue(Matcher.inQuietHours(listOf(22, 9), at(3)))
        assertFalse(Matcher.inQuietHours(listOf(22, 9), at(12)))
        assertFalse(Matcher.inQuietHours(null, at(23)))
    }

    @Test
    fun decodesTokenPayloadWithoutVerifying() {
        // header {"alg":"none"} . payload . (empty signature)
        val payload = """{"sub":"sandbox_user_0001","attrs":{"gender":"female","birth_year":1992,"lang":"ku"},"exp":4102444800}"""
        val b64 = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toByteArray())
        val t = TokenInfo.decode("eyJhbGciOiJub25lIn0.$b64.")
        assertNotNull(t)
        assertEquals("sandbox_user_0001", t!!.sub)
        assertEquals("ku", t.lang)
        assertEquals(16, t.subHash.length)
        assertNull(TokenInfo.decode("garbage"))
    }

    @Test
    fun parsesConfig() {
        val cfg = parseSurveys(offerJson).config!!
        assertEquals(240, cfg.checkIntervalMinutes)
        assertEquals(listOf(22, 9), cfg.quietHours)
    }

    @Test
    fun carriedAttrsListsEveryAttributeInVocabularyOrder() {
        // The consent screen lists everything the token carries, not only what the study's conditions use.
        val all = TokenInfo("sub", mapOf("lang" to "ku", "city" to "erbil", "gender" to "female", "birth_year" to 1991, "governorate" to "erbil"), null)
        assertEquals(listOf("gender", "birth_year", "governorate", "city", "lang"), all.carriedAttrs)
        assertEquals(listOf("city"), TokenInfo("sub", mapOf("city" to "erbil", "gender" to null), null).carriedAttrs)
        assertEquals(emptyList<String>(), TokenInfo("sub", emptyMap(), null).carriedAttrs)
    }
}
