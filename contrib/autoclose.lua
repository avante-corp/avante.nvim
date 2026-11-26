vim.api.nvim_create_autocmd({ 'User' }, {
    pattern = 'AvanteViewBufferUpdated',
    desc = 'Quit Neovim after receiving an Avante answer',
    callback = function()
        vim.notify('Avante answered: closing')
        -- Leave the event callback before closing all windows, including modified buffers.
        vim.schedule(function()
            vim.notify('Avante: deferred closing')
            vim.cmd('qall!')
        end)
    end,
})


