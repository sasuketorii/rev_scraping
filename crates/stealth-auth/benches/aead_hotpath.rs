// SPDX-License-Identifier: MIT
//
// Lane K K.7 — criterion microbenches for stealth-auth AEAD hot paths.
//
// Two hot paths:
//   - encrypt : XChaCha20-Poly1305 encrypt + envelope encode for a
//     realistic 4 KiB cookie blob.
//   - decrypt : envelope decode + XChaCha20-Poly1305 decrypt of the same.
//
// Throughput is reported in bytes/sec so the criterion plot is directly
// comparable to other hot-path benches in the workspace.
//
// Run locally:
//   cargo bench -p stealth-auth --bench aead_hotpath

use criterion::{black_box, criterion_group, criterion_main, Criterion, Throughput};
use stealth_auth::crypto::{decrypt, encrypt};

const PROFILE: &str = "bench-profile";
const AAD_CTX: &str = "bench-context";

fn typical_blob() -> Vec<u8> {
    // 4 KiB is the documented typical cookie + metadata size.
    let mut v = Vec::with_capacity(4096);
    let chunk = b"k=v; cookie=value; path=/; HttpOnly; SameSite=Lax\n";
    while v.len() + chunk.len() <= 4096 {
        v.extend_from_slice(chunk);
    }
    while v.len() < 4096 {
        v.push(b'.');
    }
    v
}

fn bench_encrypt(c: &mut Criterion) {
    let pt = typical_blob();
    let key = [0x42_u8; 32];
    let bytes = pt.len() as u64;

    let mut group = c.benchmark_group("aead_encrypt");
    group.throughput(Throughput::Bytes(bytes));
    group.bench_function("xchacha20poly1305/4kib", |b| {
        b.iter(|| {
            let out = encrypt(
                black_box(PROFILE),
                black_box(AAD_CTX),
                black_box(&key),
                black_box(&pt),
            )
            .expect("encrypt ok");
            black_box(out);
        });
    });
    group.finish();
}

fn bench_decrypt(c: &mut Criterion) {
    let pt = typical_blob();
    let key = [0x42_u8; 32];
    let encoded = encrypt(PROFILE, AAD_CTX, &key, &pt).expect("encrypt ok");
    let bytes = pt.len() as u64;

    let mut group = c.benchmark_group("aead_decrypt");
    group.throughput(Throughput::Bytes(bytes));
    group.bench_function("xchacha20poly1305/4kib", |b| {
        b.iter(|| {
            let out = decrypt(
                black_box(PROFILE),
                black_box(AAD_CTX),
                black_box(&key),
                black_box(&encoded),
            )
            .expect("decrypt ok");
            black_box(out);
        });
    });
    group.finish();
}

criterion_group!(benches, bench_encrypt, bench_decrypt);
criterion_main!(benches);
