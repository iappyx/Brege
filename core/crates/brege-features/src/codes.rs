//! Verification codes in phone notifications ("Your code is 482913"), so the Mac can offer
//! Copy Code, like macOS does for codes in Messages.
//!
//! Deliberately conservative: a code is only taken from text that also says it is a code, and
//! amounts, phone numbers, times, dates, years and account or card numbers are skipped.

/// Words that mark a message as carrying a one-time code, in the languages Brêge ships with
/// and the ones services commonly use. Matched anywhere in a word.
const KEYWORDS: &[&str] = &[
    "code",
    "otp",
    "passcode",
    "password",
    "pincode",
    "verification",
    "verify",
    "one-time",
    "2fa",
    "security",
    "login",
    "log in",
    "sign in",
    "sign-in",
    "authenticat",
    "verificatie",
    "wachtwoord",
    "inlog",
    "toegangs",
    "bevestigings",
    "eenmalig",
    "bestätigung",
    "sicherheits",
    "anmelde",
    "código",
    "codice",
];

/// Short keywords that only count as whole words ("PIN: 4829", "Ihre TAN", not "important").
const WORD_KEYWORDS: &[&str] = &["pin", "tan", "kod"];

/// "code" inside these words is not about a one-time code.
const NOT_CODE_PREFIXES: &[&str] = &[
    "post", "postal ", "zip", "zip ", "bar", "area ", "country ", "qr", "qr-", "qr ",
];

/// Words shortly before a number that make it an account, card or IBAN number.
const ACCOUNT_WORDS: &[&str] = &[
    "rekening",
    "account",
    "ending",
    "card",
    "pas",
    "pasnummer",
    "kaart",
    "iban",
    "eindigend",
    "konto",
    "karte",
    "endet",
];

/// Currency words next to a number make it an amount.
const CURRENCY_WORDS: &[&str] = &["eur", "euro", "euros", "usd", "gbp", "chf"];

/// Lowercases `text` without changing byte offsets (characters whose lowercase form has another
/// length stay as they are), so positions in both strings match.
fn lowercase_same_offsets(text: &str) -> String {
    text.chars()
        .map(|c| {
            let mut lower = c.to_lowercase();
            match (lower.next(), lower.next()) {
                (Some(l), None) if l.len_utf8() == c.len_utf8() => l,
                _ => c,
            }
        })
        .collect()
}

/// Byte ranges of keywords in `lower`.
fn keyword_spans(lower: &str) -> Vec<(usize, usize)> {
    let mut spans: Vec<(usize, usize)> = KEYWORDS
        .iter()
        .flat_map(|k| lower.match_indices(k).map(|(i, m)| (i, i + m.len())))
        .filter(|&(i, _)| {
            !lower.as_bytes()[i..].starts_with(b"code")
                || !NOT_CODE_PREFIXES.iter().any(|p| lower[..i].ends_with(p))
        })
        .collect();
    for word in WORD_KEYWORDS {
        spans.extend(
            lower
                .match_indices(word)
                .map(|(i, m)| (i, i + m.len()))
                .filter(|&(i, end)| {
                    !lower[..i]
                        .chars()
                        .next_back()
                        .is_some_and(char::is_alphanumeric)
                        && !lower[end..].chars().next().is_some_and(char::is_alphabetic)
                }),
        );
    }
    spans
}

/// Up to three words before byte `start`, nearest first, stopping at a word with digits.
fn words_before(lower: &str, start: usize) -> impl Iterator<Item = &str> {
    lower[..start]
        .split_whitespace()
        .rev()
        .take(3)
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
        .take_while(|w| !w.chars().any(|c| c.is_ascii_digit()))
}

fn is_date(groups: &[String]) -> bool {
    let n: Vec<u32> = groups.iter().map(|g| g.parse().unwrap_or(0)).collect();
    groups.len() == 3
        && groups.iter().all(|g| g.len() == 2)
        && (1..=31).contains(&n[0])
        && (1..=12).contains(&n[1])
}

/// Returns the code (digits only, as sites expect them) or `None`.
pub fn detect(text: &str) -> Option<String> {
    let lower = lowercase_same_offsets(text);
    let keywords = keyword_spans(&lower);
    if keywords.is_empty() {
        return None;
    }
    // A first line of only digits is a short-code SMS sender shown as the title, not a code.
    let sender_line_end = text
        .split_once('\n')
        .filter(|(first, _)| {
            let first = first.trim();
            !first.is_empty() && first.chars().all(|c| c.is_ascii_digit() || c == '+')
        })
        .map_or(0, |(first, _)| first.len());

    let chars: Vec<(usize, char)> = text.char_indices().collect();
    // (after a keyword, distance to it, code)
    let mut best: Option<(bool, usize, String)> = None;
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].1.is_ascii_digit() {
            i += 1;
            continue;
        }
        // A run of digit groups joined by single spaces or dashes ("123 456", "90 21 44"). The
        // whole run is taken, so the end of a longer number ("+31 6 1234 5678") is never read
        // as a code of its own.
        let start = i;
        let mut groups: Vec<String> = vec![String::new()];
        let mut dashed = false;
        let mut j = i;
        while j < chars.len() {
            let c = chars[j].1;
            if c.is_ascii_digit() {
                groups.last_mut().expect("one group").push(c);
            } else if (c == ' ' || c == '-')
                && chars.get(j + 1).is_some_and(|&(_, n)| n.is_ascii_digit())
            {
                dashed |= c == '-';
                groups.push(String::new());
            } else {
                break;
            }
            j += 1;
        }
        i = j;
        let digits: String = groups.concat();
        let byte_start = chars[start].0;
        let byte_end = chars.get(j).map_or(text.len(), |&(b, _)| b);
        if byte_start < sender_line_end {
            continue;
        }
        // Distance to the nearest keyword that ends before the number.
        let preceding = keywords
            .iter()
            .filter(|&&(_, end)| end <= byte_start)
            .map(|&(_, end)| byte_start - end)
            .min();
        // A keyword right before it: only punctuation and spaces in between ("Code: 1234 5678").
        let keyword_adjacent = keywords.iter().any(|&(_, end)| {
            end <= byte_start && text[end..byte_start].chars().all(|c| !c.is_alphanumeric())
        });

        // Split codes come in equal groups of two or three digits, or two groups of four right
        // after a keyword; dates (13-09-26), phone numbers (0800-1234) and long numbers do not.
        let split_ok = groups.len() == 1
            || (groups.len() <= 3
                && groups.iter().all(|g| g.len() == groups[0].len())
                && (2..=3).contains(&groups[0].len())
                && !(dashed && is_date(&groups)))
            || (groups.len() == 2 && groups.iter().all(|g| g.len() == 4) && keyword_adjacent);
        if !split_ok {
            continue;
        }

        let before = start.checked_sub(1).map(|k| chars[k].1);
        let after = chars.get(j).map(|&(_, c)| c);
        // A sign one space away still counts ("€ 2500", "2500 €", "**** 1234").
        let before_spaced = start
            .checked_sub(2)
            .filter(|_| before == Some(' '))
            .map(|k| chars[k].1);
        let after_spaced = chars
            .get(j + 1)
            .filter(|_| after == Some(' '))
            .map(|&(_, c)| c);
        if matches!(before_spaced, Some('€' | '$' | '£' | '*' | '•'))
            || matches!(after_spaced, Some('€' | '$' | '£'))
        {
            continue;
        }
        if !(4..=8).contains(&digits.len())
            || matches!(
                before,
                Some('+' | '€' | '$' | '£' | '#' | ',' | '.' | ':' | '/' | '*' | '•')
            )
            || matches!(after, Some('%' | ',' | '.' | ':' | '/' | '€'))
                && chars.get(j + 1).is_some_and(|&(_, c)| c.is_ascii_digit())
            || matches!(after, Some('%' | '€'))
            // Also masked numbers ("xxxx1234").
            || before.is_some_and(|c| c.is_alphabetic() && c != 'G')
            || after.is_some_and(char::is_alphanumeric)
        {
            continue;
        }
        // Years are rarely codes.
        if digits.len() == 4 && (1900..=2099).contains(&digits.parse::<u32>().unwrap_or(0)) {
            continue;
        }
        // Account and card numbers, and amounts with a currency word.
        let previous: Vec<&str> = words_before(&lower, byte_start).collect();
        let near = previous.iter().any(|w| ACCOUNT_WORDS.contains(w));
        let currency_before = previous.first().is_some_and(|w| CURRENCY_WORDS.contains(w));
        let currency_after = lower[byte_end..]
            .split_whitespace()
            .next()
            .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
            .is_some_and(|w| CURRENCY_WORDS.contains(&w));
        if near || currency_before || currency_after {
            continue;
        }

        let after_keyword = preceding.is_some();
        let distance = preceding.unwrap_or_else(|| {
            keywords
                .iter()
                .map(|&(k, _)| k.abs_diff(byte_start))
                .min()
                .unwrap_or(usize::MAX)
        });
        // Prefer a code that follows a keyword, then the nearest; six digits win ties.
        let better = match &best {
            None => true,
            Some((a, d, code)) => {
                (after_keyword && !a)
                    || (after_keyword == *a
                        && (distance < *d
                            || (distance == *d && digits.len() == 6 && code.len() != 6)))
            }
        };
        if better {
            best = Some((after_keyword, distance, digits));
        }
    }
    best.map(|(_, _, code)| code)
}

#[cfg(test)]
mod tests {
    use super::detect;

    #[test]
    fn finds_codes() {
        for (text, code) in [
            ("Je verificatiecode is 482913", "482913"),
            ("G-482913 is your Google verification code.", "482913"),
            ("Your WhatsApp code: 123-456", "123456"),
            ("Use 7788 as your login code", "7788"),
            ("Uw eenmalige inlogcode: 90 21 44", "902144"),
            ("<#> 551234 is je Microsoft-beveiligingscode", "551234"),
            (
                "Dein Bestätigungscode lautet 3829. Gültig für 10 Minuten.",
                "3829",
            ),
            (
                "Code 612734 — valid for 5 minutes. Order 2026-09-13.",
                "612734",
            ),
            // Found by review: the code after the keyword, not a number before it.
            (
                "Je verificatiecode voor rekening ***1234 is 567890",
                "567890",
            ),
            ("3669\nVerificatiecode: 482913", "482913"),
            ("3669\nJe verificatiecode is 482913", "482913"),
            (
                "Bank\nJe verificatiecode voor rekening ***1234 is 567890",
                "567890",
            ),
            (
                "Your verification code for account ending 1234 is 567890",
                "567890",
            ),
            ("Rabobank\nCode 482913", "482913"),
            // More realistic messages.
            ("Your one time password is 839201", "839201"),
            ("Ihre TAN lautet 482193", "482193"),
            ("PIN: 4829", "4829"),
            ("Your code: 1234 5678", "12345678"),
            ("123456 is your Instagram code. Don't share it.", "123456"),
            ("Your Amazon OTP is 482913. Do not share it.", "482913"),
            ("Dein Anmeldecode: 772910", "772910"),
            ("Bol: gebruik code 667788 om in te loggen", "667788"),
            ("Uw eenmalige code is 3829 (geldig tot 14:05)", "3829"),
            ("Verification code 482913 for account ending 1234", "482913"),
            ("Uw verificatiecode is 551 234", "551234"),
            ("DigiD: je sms-code is 482913", "482913"),
            ("Ihr Sicherheitscode für Konto ***4821: 118822", "118822"),
        ] {
            assert_eq!(detect(text).as_deref(), Some(code), "{text}");
        }
    }

    #[test]
    fn ignores_non_codes() {
        for text in [
            "Your order #12345678 has shipped",
            "Call me back on +31612345678",
            "Meeting at 12:30 in room 2044",
            "Pay €1234 before Friday",
            "Discount code SUMMER: 25% off until 2026",
            "Je pakket komt tussen 14:00 en 16:00",
            "New sign-in to your account on 13-09-2026",
            "New login on 2026-09-13 from Chrome",
            "Login alert: not you? Call +31 6 1234 5678",
            "Security question? Call our fraud line 0800-1234",
            "Security: payment of € 2500 approved",
            "Security: payment of 2500 € approved",
            // More realistic messages.
            "Uw postcode is 1234 AB",
            "Barcode 87123456 scannen bij de kassa",
            "Pakket bezorgd op 13-09-26, code volgt",
            "Security alert: payment of EUR 2500 on card ending 4821",
            "Login: charge of 1500 USD declined",
            "Your card ending in 4821 was used to log in",
            "Inlog op rekening 12345678 gelukt",
            "Your 2FA backup: call 1234 5678",
            "3669\nYour login alert from Chrome",
            "Beveiligingscode niet gevraagd? Pas ***1234 geblokkeerd",
            "Kaart 4821 geblokkeerd, verificatie nodig",
            "Important instant update 482913",
            "Anmeldung von Karte xxxx4821 bestätigt, Sicherheitshinweis",
        ] {
            assert_eq!(detect(text), None, "{text}");
        }
    }
}
