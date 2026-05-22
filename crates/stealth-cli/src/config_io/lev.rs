// SPDX-License-Identifier: MIT
// Source: new module for rev_scraping v1.2.0 (P5.1)

pub fn distance(a: &str, b: &str) -> usize {
    if a == b {
        return 0;
    }
    if a.is_empty() {
        return b.chars().count();
    }
    if b.is_empty() {
        return a.chars().count();
    }

    let b_chars: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b_chars.len()).collect();
    let mut cur = vec![0; b_chars.len() + 1];

    for (i, ca) in a.chars().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b_chars.iter().enumerate() {
            let substitution = usize::from(ca != *cb);
            cur[j + 1] = (prev[j + 1] + 1)
                .min(cur[j] + 1)
                .min(prev[j] + substitution);
        }
        std::mem::swap(&mut prev, &mut cur);
    }

    prev[b_chars.len()]
}
