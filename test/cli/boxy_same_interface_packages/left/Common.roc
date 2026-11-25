Common := { n : U64 }.{
    make : U64 -> Common
    make = |n| { n: n }

    tell : Common -> Str
    tell = |s| "left ${s.n.to_str()}"
}
