# config/.credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        excluded: [
          ~r"/test/support/test_handler.ex",
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/"
        ]
      },
      checks: [
        {Credo.Check.Readability.LargeNumbers, only_greater_than: 86400},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, parens: true},
        {Credo.Check.Design.TagTODO, false}
      ]
    }
  ]
}
