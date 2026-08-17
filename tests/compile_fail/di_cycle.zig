const am = @import("akamata");
const A = struct {};
const B = struct {};
const PA = am.di.Provider(A, .application, &.{B});
const PB = am.di.Provider(B, .application, &.{A});
comptime {
    am.di.validate(&.{ PA, PB });
}
