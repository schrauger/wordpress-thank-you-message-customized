wp.blocks.registerBlockType('donor-thank-you/message', {
    title: 'Donor Thank You',
    icon: 'heart',
    category: 'widgets',
    edit: function() { return wp.element.createElement('p', null, 'Donor Thank You Message'); },
    save: function() { return null; } // server-side rendered
});
