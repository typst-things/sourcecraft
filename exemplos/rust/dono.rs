pub mod pessoas {
    pub struct Dono { pub nome: String }
    pub struct Brinquedo;
    pub struct Coleira(pub u32, Rc<Dono>);
}
