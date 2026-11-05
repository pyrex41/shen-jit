/* The programs of numeric.shen in C: the same work, in the same order, on the same memory layout. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void report(const char *name, double check, double t0)
{
    printf("%s %g s check %.17g\n", name, now() - t0, check);
}

static void matmul(long n)
{
    double *a = calloc((size_t)(n * n), 8), *b = calloc((size_t)(n * n), 8), *c = calloc((size_t)(n * n), 8);
    for (long i = 0; i < n; i++)
        for (long j = 0; j < n; j++) {
            a[i * n + j] = 1.0 / (double)(i + j + 1);
            b[i * n + j] = 1.0 + 0.5 * (double)(i - j);
        }
    double t0 = now();
    for (long i = 0; i < n; i++)
        for (long j = 0; j < n; j++) {
            double acc = 0.0;
            for (long k = 0; k < n; k++)
                acc += a[i * n + k] * b[k * n + j];
            c[i * n + j] = acc;
        }
    double t = 0;
    for (long i = 0; i < n; i++)
        t += c[i * n + i];
    report("matmul", t, t0);
}

static void mandelbrot(long size, long limit)
{
    double t0 = now(), step = 3.0 / (double)size;
    long check = 0;
    for (long j = 0; j < size; j++) {
        double cy = -1.5 + (double)j * step;
        for (long i = 0; i < size; i++) {
            double cx = -2.0 + (double)i * step, x = 0, y = 0;
            long n = 0;
            for (; n < limit; n++) {
                double xx = x * x, yy = y * y;
                if (xx + yy > 4.0)
                    break;
                y = 2.0 * (x * y) + cy;
                x = xx - yy + cx;
            }
            check += n;
        }
    }
    report("mandelbrot", (double)check, t0);
}

static double sn_a(long i, long j) { return 1.0 / (0.5 * (double)(i + j) * (double)(i + j + 1) + (double)i + 1.0); }

static void sn_times(const double *v, double *out, int t, long n)
{
    for (long i = 0; i < n; i++) {
        double acc = 0.0;
        for (long j = 0; j < n; j++)
            acc += (t ? sn_a(j, i) : sn_a(i, j)) * v[j];
        out[i] = acc;
    }
}

static void spectral(long n)
{
    double *u = calloc((size_t)n, 8), *v = calloc((size_t)n, 8), *tmp = calloc((size_t)n, 8);
    for (long i = 0; i < n; i++)
        u[i] = 1.0;
    double t0 = now();
    for (int k = 0; k < 10; k++) {
        sn_times(u, tmp, 0, n);
        sn_times(tmp, v, 1, n);
        sn_times(v, tmp, 0, n);
        sn_times(tmp, u, 1, n);
    }
    double uv = 0, vv = 0;
    for (long i = 0; i < n; i++) {
        uv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    report("spectral", uv / vv, t0);
}

static void nbody(long n, long steps)
{
    double *b = calloc((size_t)n, 56), dt = 0.01;
#define B(i, f) b[(i) * 7 + (f)]
    for (long i = 0; i < n; i++) {
        double d = (double)i;
        B(i, 0) = 1.25 * d;
        B(i, 1) = 7.0 - 0.5 * d;
        B(i, 2) = 0.25 * (d * d);
        B(i, 3) = 0.125 * (3.0 - d);
        B(i, 4) = 0.0625 * d;
        B(i, 5) = 0.03125 - 0.01 * d;
        B(i, 6) = 1.0 + 0.5 * d;
    }
    double t0 = now();
    for (long s = 0; s < steps; s++) {
        for (long i = 0; i < n; i++)
            for (long j = i + 1; j < n; j++) {
                double dx = B(i, 0) - B(j, 0), dy = B(i, 1) - B(j, 1), dz = B(i, 2) - B(j, 2);
                double d2 = dx * dx + dy * dy + dz * dz, mag = dt / (d2 * sqrt(d2));
                double mi = B(i, 6) * mag, mj = B(j, 6) * mag;
                B(i, 3) -= dx * mj;
                B(i, 4) -= dy * mj;
                B(i, 5) -= dz * mj;
                B(j, 3) += dx * mi;
                B(j, 4) += dy * mi;
                B(j, 5) += dz * mi;
            }
        for (long i = 0; i < n; i++) {
            B(i, 0) += dt * B(i, 3);
            B(i, 1) += dt * B(i, 4);
            B(i, 2) += dt * B(i, 5);
        }
    }
    report("nbody", B(0, 0), t0);
#undef B
}

static void heat(long w, long h, long sweeps)
{
    double *g = calloc((size_t)(w * h), 8);
    for (long i = 0; i < w; i++)
        g[i] = 100.0;
    double t0 = now();
    for (long k = 0; k < sweeps; k++)
        for (int colour = 0; colour < 2; colour++)
            for (long j = 1; j < h - 1; j++) {
                long odd = (j + colour) & 1;
                for (long i = 1 + odd; i < w - 1; i += 2)
                    g[j * w + i] = 0.25 * ((g[j * w + i - 1] + g[j * w + i + 1]) + (g[(j - 1) * w + i] + g[(j + 1) * w + i]));
            }
    report("heat", g[(h / 2) * w + w / 2], t0);
}

int main(void)
{
    matmul(400);
    mandelbrot(400, 200);
    spectral(500);
    nbody(64, 200);
    heat(512, 512, 200);
    return 0;
}
