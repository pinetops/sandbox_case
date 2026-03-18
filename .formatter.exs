[
  export: [
    locals_without_parens: [
      plug_if_loaded: 1,
      plug_if_loaded: 2,
      on_mount_if_loaded: 1,
      on_mount_if_loaded: 2
    ]
  ],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
