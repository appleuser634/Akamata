const am = @import("akamata");
const A = struct {};
const B = struct {};
const PA = am.di.Provider(A, .application, &.{B});
comptime {
    am.di.validate(&.{PA});
}
